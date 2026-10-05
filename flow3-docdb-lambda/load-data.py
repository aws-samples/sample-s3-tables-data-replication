#!/usr/bin/env python3
"""Load sample product data into DocumentDB via a temporary Lambda in the VPC."""

import boto3
import os
import json
import io
import zipfile
import time

REGION = boto3.session.Session().region_name or "us-east-1"
STACK_NAME = "zero-etl-workshop-flow3"
# Processor Lambda name:
#   - CloudFormation path: fixed name below.
#   - Terraform path: set FLOW3_PROCESSOR_FUNCTION (e.g. "<project_name>-flow3-processor"
#     with the random suffix). The temporary loader Lambda name is derived from it.
PROCESSOR_FUNCTION = os.environ.get("FLOW3_PROCESSOR_FUNCTION", "zero-etl-workshop-flow3-processor")
LOADER_FUNCTION = PROCESSOR_FUNCTION.replace("-processor", "-loader")
TOTAL_RECORDS = 2000

LOADER_CODE = '''
import json, os, random, urllib.request, subprocess, sys

def handler(event, context):
    subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pymongo', '-t', '/tmp/pip', '-q'])
    sys.path.insert(0, '/tmp/pip')
    import pymongo

    sm = __import__('boto3').client('secretsmanager')
    secret = json.loads(sm.get_secret_value(SecretId=os.environ['SECRET_ARN'])['SecretString'])
    endpoint = os.environ['DOCDB_ENDPOINT']

    urllib.request.urlretrieve('https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem', '/tmp/ca.pem')
    client = pymongo.MongoClient(
        f"mongodb://{secret['username']}:{secret['password']}@{endpoint}:27017/"
        "?tls=true&tlsCAFile=/tmp/ca.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false"
    )
    col = client['workshop']['products']

    categories = ['Electronics','Books','Clothing','Home','Sports','Toys','Food','Auto']
    adj = ['Premium','Basic','Pro','Ultra','Mini','Max','Eco','Smart']
    nouns = ['Widget','Gadget','Device','Tool','Kit','Set','Pack','Bundle']

    start = event.get('start', 0)
    total = event.get('total', 500)
    docs = []
    for i in range(start, start + total):
        docs.append({
            'product_id': f'PROD-{i:06d}',
            'name': f'{random.choice(adj)} {random.choice(nouns)} {i}',
            'category': random.choice(categories),
            'price': round(random.uniform(4.99, 499.99), 2),
            'stock': random.randint(0, 1000),
            'rating': round(random.uniform(1.0, 5.0), 1),
            'updated_at': f'2024-{random.randint(1,12):02d}-{random.randint(1,28):02d}T{random.randint(0,23):02d}:00:00Z'
        })
    if docs:
        col.insert_many(docs)
    return {'inserted': len(docs), 'total': col.count_documents({})}
'''


def get_output(cfn, key):
    for o in cfn.describe_stacks(StackName=STACK_NAME)["Stacks"][0]["Outputs"]:
        if o["OutputKey"] == key:
            return o["OutputValue"]
    raise KeyError(key)


def make_zip(code):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.writestr('index.py', code)
    return buf.getvalue()


def main():
    lam = boto3.client("lambda", region_name=REGION)
    iam = boto3.client("iam", region_name=REGION)

    # Secret ARN + DocumentDB endpoint resolution:
    #   - Terraform path: set DOCDB_SECRET_ARN and DOCDB_ENDPOINT (no CloudFormation stack exists).
    #   - CloudFormation path: leave them unset; values are read from the CFN stack outputs.
    secret_arn = os.environ.get("DOCDB_SECRET_ARN")
    endpoint = os.environ.get("DOCDB_ENDPOINT")
    if not (secret_arn and endpoint):
        cfn = boto3.client("cloudformation", region_name=REGION)
        secret_arn = secret_arn or get_output(cfn, "DocDBSecretArn")
        endpoint = endpoint or get_output(cfn, "DocDBClusterEndpoint")

    # Get VPC config from the processor Lambda
    proc = lam.get_function(FunctionName=PROCESSOR_FUNCTION)
    vpc = proc["Configuration"]["VpcConfig"]
    role_arn = proc["Configuration"]["Role"]

    # Ensure role has SecretsManager access
    role_name = role_arn.split("/")[-1]
    iam.put_role_policy(
        RoleName=role_name, PolicyName="SecretsAccess",
        PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
            {"Effect": "Allow", "Action": ["secretsmanager:GetSecretValue"], "Resource": [secret_arn]}
        ]})
    )

    # Create loader Lambda
    print("Creating loader Lambda...")
    try:
        lam.delete_function(FunctionName=LOADER_FUNCTION)
    except:
        pass

    lam.create_function(
        FunctionName=LOADER_FUNCTION, Runtime="python3.12", Handler="index.handler",
        Role=role_arn, Code={"ZipFile": make_zip(LOADER_CODE)},
        Timeout=300, MemorySize=512,
        VpcConfig={"SubnetIds": vpc["SubnetIds"], "SecurityGroupIds": vpc["SecurityGroupIds"]},
        Environment={"Variables": {"SECRET_ARN": secret_arn, "DOCDB_ENDPOINT": endpoint}},
    )
    print("Waiting for Lambda to be active...")
    lam.get_waiter("function_active_v2").wait(FunctionName=LOADER_FUNCTION)

    print(f"Loading {TOTAL_RECORDS} products...")
    batch = 500
    for start in range(0, TOTAL_RECORDS, batch):
        count = min(batch, TOTAL_RECORDS - start)
        resp = lam.invoke(
            FunctionName=LOADER_FUNCTION, InvocationType="RequestResponse",
            Payload=json.dumps({"start": start, "total": count}),
        )
        result = json.loads(resp["Payload"].read())
        if "errorMessage" in result:
            print(f"  Error: {result['errorMessage']}")
            print(f"  Trace: {result.get('stackTrace', [''])[0]}")
            return
        print(f"  Loaded {start + count}/{TOTAL_RECORDS} (DB total: {result.get('total', '?')})")

    print("Cleaning up loader Lambda...")
    lam.delete_function(FunctionName=LOADER_FUNCTION)
    print("Done!")


if __name__ == "__main__":
    main()
