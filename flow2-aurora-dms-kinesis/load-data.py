#!/usr/bin/env python3
"""Load sample customer data into Aurora PostgreSQL via RDS Data API."""

import boto3
import os
import random

REGION = boto3.session.Session().region_name or "us-east-1"
STACK_NAME = "zero-etl-workshop-flow2"
SHARED_STACK = "zero-etl-workshop-shared"
DB_NAME = "postgres"
TOTAL_RECORDS = 2000

FIRST_NAMES = ["James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael", "Linda", "David", "Elizabeth"]
LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez"]
CITIES = ["New York", "Los Angeles", "Chicago", "Houston", "Phoenix", "Philadelphia", "San Antonio", "San Diego", "Dallas", "Austin"]
DOMAINS = ["example.com", "example.org", "example.net", "mail.example.org", "test.example.com"]


def get_output(cfn, stack, key):
    for o in cfn.describe_stacks(StackName=stack)["Stacks"][0]["Outputs"]:
        if o["OutputKey"] == key:
            return o["OutputValue"]
    raise KeyError(f"{key} not found in {stack}")


def run_sql(rds_data, cluster_arn, secret_arn, sql, parameters=None):
    kwargs = {
        "resourceArn": cluster_arn,
        "secretArn": secret_arn,
        "database": DB_NAME,
        "sql": sql,
    }
    if parameters is not None:
        kwargs["parameters"] = parameters
    return rds_data.execute_statement(**kwargs)


def main():
    rds_data = boto3.client("rds-data", region_name=REGION)

    # ARN resolution:
    #   - Terraform path: set AURORA_CLUSTER_ARN and AURORA_SECRET_ARN (no CloudFormation stack exists).
    #   - CloudFormation path: leave them unset; the ARNs are read from the CFN stack outputs.
    cluster_arn = os.environ.get("AURORA_CLUSTER_ARN")
    secret_arn = os.environ.get("AURORA_SECRET_ARN")
    if not (cluster_arn and secret_arn):
        cfn = boto3.client("cloudformation", region_name=REGION)
        cluster_arn = cluster_arn or get_output(cfn, STACK_NAME, "AuroraClusterArn")
        secret_arn = secret_arn or get_output(cfn, STACK_NAME, "AuroraSecretArn")
    print(f"Cluster: {cluster_arn}")

    print("Creating customers table...")
    run_sql(rds_data, cluster_arn, secret_arn, """
        CREATE TABLE IF NOT EXISTS customers (
            customer_id SERIAL PRIMARY KEY,
            first_name VARCHAR(50),
            last_name VARCHAR(50),
            email VARCHAR(100),
            city VARCHAR(50),
            signup_date DATE,
            total_orders INTEGER DEFAULT 0,
            total_spent DOUBLE PRECISION DEFAULT 0.0
        )
    """)

    print(f"Inserting {TOTAL_RECORDS} customers...")
    batch_size = 100
    for batch_start in range(0, TOTAL_RECORDS, batch_size):
        placeholders = []
        parameters = []
        for i in range(batch_start, min(batch_start + batch_size, TOTAL_RECORDS)):
            fn = random.choice(FIRST_NAMES)
            ln = random.choice(LAST_NAMES)
            email = f"{fn.lower()}.{ln.lower()}{i}@{random.choice(DOMAINS)}"
            city = random.choice(CITIES)
            signup = f"2024-{random.randint(1,12):02d}-{random.randint(1,28):02d}"
            orders = random.randint(0, 50)
            spent = round(random.uniform(0, 5000), 2)
            # Bind every row value as an RDS Data API named parameter (unique per-row
            # suffix) so no Python value is concatenated into the SQL string.
            placeholders.append(
                f"(:fn{i},:ln{i},:email{i},:city{i},:signup{i},:orders{i},:spent{i})"
            )
            parameters.extend([
                {"name": f"fn{i}", "value": {"stringValue": fn}},
                {"name": f"ln{i}", "value": {"stringValue": ln}},
                {"name": f"email{i}", "value": {"stringValue": email}},
                {"name": f"city{i}", "value": {"stringValue": city}},
                {"name": f"signup{i}", "value": {"stringValue": signup}},
                {"name": f"orders{i}", "value": {"longValue": orders}},
                {"name": f"spent{i}", "value": {"doubleValue": spent}},
            ])

        sql = (
            "INSERT INTO customers "
            "(first_name,last_name,email,city,signup_date,total_orders,total_spent) "
            f"VALUES {','.join(placeholders)}"
        )
        run_sql(rds_data, cluster_arn, secret_arn, sql, parameters=parameters)

        loaded = min(batch_start + batch_size, TOTAL_RECORDS)
        if loaded % 500 == 0 or loaded == TOTAL_RECORDS:
            print(f"  Loaded {loaded}/{TOTAL_RECORDS}")

    resp = run_sql(rds_data, cluster_arn, secret_arn, "SELECT COUNT(*) FROM customers")
    count = resp["records"][0][0]["longValue"]
    print(f"Total records: {count}")
    print("Done!")


if __name__ == "__main__":
    main()
