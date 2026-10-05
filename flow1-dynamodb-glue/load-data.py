#!/usr/bin/env python3
"""Load sample order data into DynamoDB for Flow 1 (Glue Zero-ETL demo)."""

import boto3
import random
import string
import time
from datetime import datetime, timedelta

import os

# Table name resolution:
#   - CloudFormation path: defaults to the fixed CFN table name.
#   - Terraform path: set DDB_TABLE_NAME (e.g. `terraform output -raw dynamodb_table_name`),
#     since Terraform names it <project_name>-orders with a random suffix.
TABLE_NAME = os.environ.get("DDB_TABLE_NAME", "zero-etl-workshop-orders")
REGION = boto3.session.Session().region_name or "us-east-1"
BATCH_SIZE = 25  # DynamoDB batch_write_item limit
TOTAL_RECORDS = 2000

PRODUCTS = ["Laptop", "Phone", "Tablet", "Monitor", "Keyboard", "Mouse", "Headphones", "Webcam", "Speaker", "Charger"]
STATUSES = ["pending", "processing", "shipped", "delivered", "cancelled"]
CITIES = ["New York", "Los Angeles", "Chicago", "Houston", "Phoenix", "Philadelphia", "San Antonio", "San Diego", "Dallas", "Austin"]

def generate_order(i):
    order_date = datetime(2024, 1, 1) + timedelta(days=random.randint(0, 365))
    product = random.choice(PRODUCTS)
    return {
        "order_id": {"S": f"ORD-{i:06d}"},
        "customer_id": {"S": f"CUST-{random.randint(1, 500):04d}"},
        "product": {"S": product},
        "quantity": {"N": str(random.randint(1, 10))},
        "price": {"N": f"{random.uniform(9.99, 999.99):.2f}"},
        "status": {"S": random.choice(STATUSES)},
        "city": {"S": random.choice(CITIES)},
        "order_date": {"S": order_date.strftime("%Y-%m-%d")},
        "created_at": {"S": order_date.isoformat()},
    }

def main():
    client = boto3.client("dynamodb", region_name=REGION)
    print(f"Loading {TOTAL_RECORDS} orders into {TABLE_NAME}...")

    for batch_start in range(0, TOTAL_RECORDS, BATCH_SIZE):
        batch_end = min(batch_start + BATCH_SIZE, TOTAL_RECORDS)
        items = [{"PutRequest": {"Item": generate_order(i)}} for i in range(batch_start + 1, batch_end + 1)]

        retries = 0
        while items:
            resp = client.batch_write_item(RequestItems={TABLE_NAME: items})
            items = resp.get("UnprocessedItems", {}).get(TABLE_NAME, [])
            if items:
                retries += 1
                time.sleep(min(2 ** retries, 30))

        if (batch_end) % 500 == 0 or batch_end == TOTAL_RECORDS:
            print(f"  Loaded {batch_end}/{TOTAL_RECORDS} records")

    print("Done!")

if __name__ == "__main__":
    main()
