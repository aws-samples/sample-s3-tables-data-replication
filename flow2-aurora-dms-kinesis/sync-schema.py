#!/usr/bin/env python3
"""
Schema Converter: Reads Aurora PostgreSQL table schemas via RDS Data API
and creates matching S3 Tables (Iceberg) targets for Amazon Data Firehose.

Usage:
    python3 sync-schema.py [--schema public] [--tables customers,orders] [--dry-run]
"""

import argparse
import json

import boto3

REGION = boto3.session.Session().region_name or "us-east-1"
FLOW2_STACK = "zero-etl-workshop-flow2"
SHARED_STACK = "zero-etl-workshop-shared"
NAMESPACE = "flow2_aurora"
DB_NAME = "postgres"

# PostgreSQL type → Iceberg type mapping
PG_TO_ICEBERG = {
    "smallint": "int", "integer": "int", "bigint": "long",
    "serial": "int", "bigserial": "long",
    "real": "float", "double precision": "double",
    "numeric": "double", "decimal": "double",
    "boolean": "boolean",
    "character varying": "string", "varchar": "string",
    "character": "string", "char": "string",
    "text": "string", "name": "string",
    "uuid": "string", "json": "string", "jsonb": "string", "xml": "string",
    "date": "date",
    "timestamp without time zone": "timestamp",
    "timestamp with time zone": "timestamptz",
    "time without time zone": "string", "time with time zone": "string",
    "interval": "string", "bytea": "binary",
    "ARRAY": "string", "USER-DEFINED": "string",
}


def get_output(cfn, stack, key):
    for o in cfn.describe_stacks(StackName=stack)["Stacks"][0]["Outputs"]:
        if o["OutputKey"] == key:
            return o["OutputValue"]
    raise KeyError(f"{key} not found in {stack}")


def query(rds_data, cluster_arn, secret_arn, sql, parameters=None):
    kwargs = {
        "resourceArn": cluster_arn, "secretArn": secret_arn,
        "database": DB_NAME, "sql": sql, "includeResultMetadata": True,
    }
    if parameters is not None:
        kwargs["parameters"] = parameters
    resp = rds_data.execute_statement(**kwargs)
    cols = [c["name"] for c in resp["columnMetadata"]]
    rows = []
    for rec in resp["records"]:
        row = {}
        for i, field in enumerate(rec):
            val = field.get("stringValue") or field.get("longValue") or field.get("booleanValue")
            row[cols[i]] = val
        rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser(description="Sync Aurora PG schema → S3 Tables")
    parser.add_argument("--schema", default="public")
    parser.add_argument("--tables", default=None, help="Comma-separated table filter")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    cfn = boto3.client("cloudformation", region_name=REGION)
    rds_data = boto3.client("rds-data", region_name=REGION)
    s3tables = boto3.client("s3tables", region_name=REGION)
    account_id = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]

    cluster_arn = get_output(cfn, FLOW2_STACK, "AuroraClusterArn")
    secret_arn = get_output(cfn, FLOW2_STACK, "AuroraSecretArn")
    table_bucket_name = get_output(cfn, SHARED_STACK, "TableBucketName")
    table_bucket_arn = f"arn:aws:s3tables:{REGION}:{account_id}:bucket/{table_bucket_name}"

    print(f"Cluster: {cluster_arn}")
    print(f"S3 Table Bucket: {table_bucket_name}")
    print(f"Target namespace: {NAMESPACE}\n")

    # Ensure namespace
    try:
        s3tables.create_namespace(tableBucketARN=table_bucket_arn, namespace=[NAMESPACE])
        print(f"Created namespace: {NAMESPACE}")
    except s3tables.exceptions.ConflictException:
        print(f"Namespace exists: {NAMESPACE}")

    # Discover tables
    # Schema name is a WHERE-clause string literal → bind as a named parameter
    # (behavior-identical, silences Bandit B608).
    tables_rows = query(rds_data, cluster_arn, secret_arn, """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = :schema AND table_type = 'BASE TABLE'
        ORDER BY table_name
    """, parameters=[{"name": "schema", "value": {"stringValue": args.schema}}])
    tables = [r["table_name"] for r in tables_rows]
    if args.tables:
        allowed = {t.strip() for t in args.tables.split(",")}
        tables = [t for t in tables if t in allowed]

    if not tables:
        print("No tables found.")
        return

    print(f"Found {len(tables)} table(s): {', '.join(tables)}\n")

    results = []
    for tbl in tables:
        # Get columns
        # Schema and table names are WHERE-clause string literals → bind as named
        # parameters (behavior-identical, silences Bandit B608).
        col_rows = query(rds_data, cluster_arn, secret_arn, """
            SELECT column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = :schema AND table_name = :table
            ORDER BY ordinal_position
        """, parameters=[
            {"name": "schema", "value": {"stringValue": args.schema}},
            {"name": "table", "value": {"stringValue": tbl}},
        ])

        # Get primary keys
        # Schema and table names are WHERE-clause string literals → bind as named
        # parameters (behavior-identical, silences Bandit B608).
        pk_rows = query(rds_data, cluster_arn, secret_arn, """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = :schema AND tc.table_name = :table
            ORDER BY kcu.ordinal_position
        """, parameters=[
            {"name": "schema", "value": {"stringValue": args.schema}},
            {"name": "table", "value": {"stringValue": tbl}},
        ])
        pk_cols = [r["column_name"] for r in pk_rows]

        # Build Iceberg schema
        fields = []
        print(f"── {tbl} ({len(col_rows)} columns, PK: {pk_cols or 'none'}) ──")
        for col in col_rows:
            iceberg_type = PG_TO_ICEBERG.get(col["data_type"], "string")
            field = {"name": col["column_name"], "type": iceberg_type}
            if col["is_nullable"] == "NO":
                field["required"] = True
            fields.append(field)
            pk = " [PK]" if col["column_name"] in pk_cols else ""
            req = " NOT NULL" if col["is_nullable"] == "NO" else ""
            print(f"  {col['column_name']:30s} {col['data_type']:30s} → {iceberg_type}{req}{pk}")

        # Create S3 Table
        if args.dry_run:
            print(f"  [dry-run] Would create: {NAMESPACE}.{tbl}")
        else:
            try:
                s3tables.create_table(
                    tableBucketARN=table_bucket_arn, namespace=NAMESPACE,
                    name=tbl, format="ICEBERG",
                    metadata={"iceberg": {"schema": {"fields": fields}}},
                )
                print(f"  S3 Table: created")
            except s3tables.exceptions.ConflictException:
                print(f"  S3 Table: exists")

        results.append({"table": tbl, "primary_keys": pk_cols, "iceberg_fields": fields})
        print()

    mapping_file = f"{__import__('os').path.dirname(__import__('os').path.abspath(__file__))}/schema-mapping.json"
    with open(mapping_file, "w") as f:
        json.dump(results, f, indent=2)
    print(f"Schema mapping written to schema-mapping.json")
    print("Done!")


if __name__ == "__main__":
    main()
