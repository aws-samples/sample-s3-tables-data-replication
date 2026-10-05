#!/usr/bin/env bash
set -euo pipefail

# Pre-flight setup for the S3 Table Buckets workshop.
# Run this ONCE per account before deploying any flows.

REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  echo "       Pick a region where both S3 Tables and Glue zero-ETL-to-S3-Tables are available (e.g. us-east-1, us-east-2, us-west-2)." >&2
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ROLE_ARN=$(aws sts get-caller-identity --query Arn --output text | sed 's|assumed-role/\(.*\)/.*|role/\1|; s|sts|iam|')

echo "Account: $ACCOUNT_ID"
echo "Role:    $CALLER_ROLE_ARN"
echo "Region:  $REGION"
echo ""

# 1. DMS VPC Role
echo "=== 1. Create dms-vpc-role ==="
aws iam create-role \
  --role-name dms-vpc-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"dms.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  2>/dev/null && echo "  Created" || echo "  Already exists"
aws iam attach-role-policy \
  --role-name dms-vpc-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole 2>/dev/null || true

# 2. Lake Formation admin (additive)
# Read-modify-write: append the caller to the existing DataLakeAdmins list instead of
# overwriting it, so we don't clobber admins other teams rely on in a shared account.
# CreateDatabase/CreateTable default permissions are preserved as-is.
echo "=== 2. Add caller to Lake Formation admins (additive) ==="
EXISTING_SETTINGS=$(aws lakeformation get-data-lake-settings \
  --region "$REGION" \
  --query 'DataLakeSettings' --output json)

MERGED_SETTINGS=$(CALLER_ROLE_ARN="$CALLER_ROLE_ARN" python3 -c '
import json, os, sys

settings = json.load(sys.stdin)
caller = os.environ["CALLER_ROLE_ARN"]

admins = settings.get("DataLakeAdmins") or []
existing = {a.get("DataLakePrincipalIdentifier") for a in admins}
if caller not in existing:
    admins.append({"DataLakePrincipalIdentifier": caller})

out = {
    "DataLakeAdmins": admins,
    "CreateDatabaseDefaultPermissions": settings.get("CreateDatabaseDefaultPermissions", []),
    "CreateTableDefaultPermissions": settings.get("CreateTableDefaultPermissions", []),
}
print(json.dumps(out))
' <<<"$EXISTING_SETTINGS")

aws lakeformation put-data-lake-settings \
  --data-lake-settings "$MERGED_SETTINGS" \
  --region "$REGION"

# 3. S3 Tables Lake Formation role
echo "=== 3. Create S3 Tables LF role ==="
aws iam create-role \
  --role-name S3TablesRoleForLakeFormation \
  --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"lakeformation.amazonaws.com\"},\"Action\":[\"sts:AssumeRole\",\"sts:SetContext\",\"sts:SetSourceIdentity\"],\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"${ACCOUNT_ID}\"}}}]}" \
  2>/dev/null && echo "  Created" || echo "  Already exists"

aws iam put-role-policy \
  --role-name S3TablesRoleForLakeFormation \
  --policy-name S3TablesAccess \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3tables:*\"],\"Resource\":[\"arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*\"]}]}"

# 4. Register S3 Tables with Lake Formation
echo "=== 4. Register S3 Tables with Lake Formation ==="
aws lakeformation register-resource \
  --resource-arn "arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/S3TablesRoleForLakeFormation" \
  --with-federation \
  --region $REGION 2>/dev/null && echo "  Registered" || echo "  Already registered"

# Enable hybrid access
aws lakeformation update-resource \
  --resource-arn "arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*" \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/S3TablesRoleForLakeFormation" \
  --with-federation \
  --hybrid-access-enabled \
  --region $REGION 2>/dev/null || true

# 5. Create s3tablescatalog
echo "=== 5. Create S3 Tables catalog ==="
aws glue create-catalog \
  --cli-input-json "{\"Name\":\"s3tablescatalog\",\"CatalogInput\":{\"FederatedCatalog\":{\"Identifier\":\"arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*\",\"ConnectionName\":\"aws:s3tables\"},\"CreateDatabaseDefaultPermissions\":[],\"CreateTableDefaultPermissions\":[],\"AllowFullTableExternalDataAccess\":\"True\"}}" \
  --region $REGION 2>/dev/null && echo "  Created" || echo "  Already exists"

# 6. Python venv
echo "=== 6. Set up Python venv ==="
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "${SCRIPT_DIR}/.venv" ]; then
  python3 -m venv "${SCRIPT_DIR}/.venv"
  source "${SCRIPT_DIR}/.venv/bin/activate"
  pip install boto3 -q
  echo "  Created .venv with boto3"
else
  echo "  .venv already exists"
fi

echo ""
echo "=== Pre-flight complete ==="
echo "Next: Run shared/deploy.sh, then each flow's deploy.sh"
