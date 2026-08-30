"""
generate_telecom_data.py

Generates a referentially-consistent set of CSV feeds for Running Telco,
matching the RAW.* table layouts exactly (same column names/order the COPY
INTO statements expect). This stands in for the real upstream systems
(CRM, mediation platform, billing engine) when you don't have live feeds -
swap this module out entirely once real source extracts are available; the
rest of the pipeline (S3 -> Snowpipe/COPY INTO -> STAGING -> CURATED) does
not need to change because the CSV contract stays identical.

Usage:
    python generate_telecom_data.py --out ./data_out --customers 5000 --cdr-per-day 20000 --days 3
"""
import argparse
import csv
import os
import random
import uuid
from datetime import datetime, timedelta

from faker import Faker

fake = Faker()
Faker.seed(42)
random.seed(42)

REGIONS = ["NORTH", "SOUTH", "EAST", "WEST"]
PLAN_CATALOG = [
    # plan_id, plan_name, plan_type, monthly_fee, data_limit_gb, voice_minutes, sms_count, currency
    ("PLN001", "Basic Prepaid 2GB", "PREPAID", 9.99, 2, 100, 100, "USD"),
    ("PLN002", "Standard Prepaid 10GB", "PREPAID", 19.99, 10, 300, 300, "USD"),
    ("PLN003", "Unlimited Postpaid", "POSTPAID", 49.99, 999, 999999, 999999, "USD"),
    ("PLN004", "Family Postpaid 50GB", "POSTPAID", 79.99, 50, 999999, 999999, "USD"),
    ("PLN005", "SME Business 100GB", "POSTPAID", 129.99, 100, 999999, 999999, "USD"),
    ("PLN006", "Enterprise Unlimited", "POSTPAID", 249.99, 999, 999999, 999999, "USD"),
]
DEVICE_MODELS = [
    ("Apple", "iPhone 15", "iOS 17"), ("Apple", "iPhone 14", "iOS 17"),
    ("Samsung", "Galaxy S24", "Android 14"), ("Samsung", "Galaxy A54", "Android 13"),
    ("Google", "Pixel 8", "Android 14"), ("OnePlus", "12", "Android 14"),
]
SEGMENTS = ["CONSUMER", "CONSUMER", "CONSUMER", "SME", "ENTERPRISE"]
ACCOUNT_STATUSES = ["ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "SUSPENDED", "CHURNED"]
TICKET_CATEGORIES = ["BILLING", "NETWORK", "DEVICE", "PLAN_CHANGE", "OTHER"]
TICKET_CHANNELS = ["CALL", "CHAT", "EMAIL", "APP"]
PAYMENT_METHODS = ["CARD", "BANK_TRANSFER", "WALLET", "CASH"]


def write_csv(path, header, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"  wrote {len(rows):>7,} rows -> {path}")


def gen_customers(n, out_dir):
    rows, ids = [], []
    for i in range(1, n + 1):
        cid = f"CUST{i:07d}"
        ids.append(cid)
        plan = random.choice(PLAN_CATALOG)
        dob = fake.date_of_birth(minimum_age=18, maximum_age=85)
        activation = fake.date_between(start_date="-5y", end_date="-1d")
        rows.append([
            cid, fake.first_name(), fake.last_name(), dob.isoformat(),
            fake.unique.bothify(text="???-##-####"),  # national_id
            fake.unique.email(), fake.msisdn()[:15],
            fake.street_address().replace("\n", " "), fake.city(),
            random.choice(REGIONS), fake.postcode(), plan[0],
            activation.isoformat(), random.choice(ACCOUNT_STATUSES),
            random.choice(SEGMENTS), random.randint(300, 850),
        ])
    write_csv(f"{out_dir}/customers/customers_{datetime.now():%Y%m%d}.csv",
        ["customer_id", "first_name", "last_name", "date_of_birth", "national_id",
         "email", "phone_number", "address_line1", "city", "region", "postal_code",
         "plan_id", "activation_date", "account_status", "customer_segment", "credit_score"],
        rows)
    return ids


def gen_plans(out_dir):
    rows = [[p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], "2023-01-01"] for p in PLAN_CATALOG]
    write_csv(f"{out_dir}/plans/plans_{datetime.now():%Y%m%d}.csv",
        ["plan_id", "plan_name", "plan_type", "monthly_fee", "data_limit_gb",
         "voice_minutes", "sms_count", "currency", "effective_date"], rows)


def gen_devices(customer_ids, out_dir):
    rows = []
    for i, cid in enumerate(customer_ids, start=1):
        if random.random() < 0.85:  # not every customer has a registered device
            make, model, os_ver = random.choice(DEVICE_MODELS)
            imei = "".join(str(random.randint(0, 9)) for _ in range(15))
            rows.append([
                f"DEV{i:07d}", imei, cid, f"{make} {model}", os_ver,
                fake.date_between(start_date="-3y", end_date="-1d").isoformat(),
                random.choice(["ACTIVE", "ACTIVE", "INACTIVE"]),
            ])
    write_csv(f"{out_dir}/devices/devices_{datetime.now():%Y%m%d}.csv",
        ["device_id", "imei", "customer_id", "device_model", "device_os",
         "activation_date", "device_status"], rows)


def gen_towers(out_dir, n=120):
    rows = []
    for i in range(1, n + 1):
        rows.append([
            f"TWR{i:05d}", random.choice(REGIONS),
            round(random.uniform(25.0, 49.0), 6), round(random.uniform(-124.0, -67.0), 6),
            random.choice([100, 250, 500, 1000]), random.choice(["ACTIVE", "ACTIVE", "MAINTENANCE"]),
        ])
    write_csv(f"{out_dir}/towers/towers_{datetime.now():%Y%m%d}.csv",
        ["tower_id", "region", "latitude", "longitude", "capacity_mbps", "tower_status"], rows)
    return [r[0] for r in rows]


def gen_cdr(customer_ids, tower_ids, out_dir, per_day, days):
    for d in range(days):
        day = datetime.now() - timedelta(days=d)
        rows = []
        for _ in range(per_day):
            cid = random.choice(customer_ids)
            call_type = random.choices(["VOICE", "SMS", "DATA"], weights=[35, 25, 40])[0]
            start = day.replace(
                hour=random.randint(0, 23), minute=random.randint(0, 59), second=random.randint(0, 59)
            )
            duration = random.randint(5, 1800) if call_type == "VOICE" else 0
            end = start + timedelta(seconds=duration)
            rows.append([
                str(uuid.uuid4()), cid, call_type, fake.msisdn()[:15], fake.msisdn()[:15],
                random.choice(tower_ids), start.strftime("%Y-%m-%d %H:%M:%S"),
                end.strftime("%Y-%m-%d %H:%M:%S"),
                duration if call_type == "VOICE" else 0,
                round(random.uniform(1, 500), 3) if call_type == "DATA" else 0,
                "Y" if random.random() < 0.03 else "N",
                random.choice(REGIONS),
            ])
        write_csv(f"{out_dir}/cdr/cdr_{day:%Y%m%d}.csv",
            ["cdr_id", "customer_id", "call_type", "origin_number", "destination_number",
             "cell_tower_id", "call_start_ts", "call_end_ts", "duration_seconds",
             "data_volume_mb", "roaming_flag", "region"], rows)


def gen_billing_and_payments(customer_ids, out_dir, months=1):
    billing_rows, payment_rows = [], []
    period = datetime.now().strftime("%Y-%m")
    for i, cid in enumerate(customer_ids, start=1):
        plan = random.choice(PLAN_CATALOG)
        usage = round(random.uniform(0, plan[3] * 0.4), 2)
        tax = round((plan[3] + usage) * 0.08, 2)
        total = round(plan[3] + usage + tax, 2)
        invoice_id = f"INV{i:07d}"
        invoice_date = datetime.now().replace(day=1)
        due = invoice_date + timedelta(days=21)
        status = random.choices(["PAID", "OPEN", "OVERDUE"], weights=[70, 20, 10])[0]
        billing_rows.append([
            invoice_id, cid, period, plan[0], usage, tax, total,
            invoice_date.date().isoformat(), due.date().isoformat(), status,
        ])
        if status == "PAID":
            payment_rows.append([
                f"PAY{i:07d}", invoice_id, cid,
                (invoice_date + timedelta(days=random.randint(0, 15))).date().isoformat(),
                total, random.choice(PAYMENT_METHODS), fake.credit_card_number()[-4:], "SUCCESS",
            ])
    write_csv(f"{out_dir}/billing/billing_{datetime.now():%Y%m%d}.csv",
        ["invoice_id", "customer_id", "billing_period", "plan_id", "usage_charges",
         "tax_amount", "total_amount", "invoice_date", "due_date", "invoice_status"], billing_rows)
    write_csv(f"{out_dir}/payments/payments_{datetime.now():%Y%m%d}.csv",
        ["payment_id", "invoice_id", "customer_id", "payment_date", "amount",
         "payment_method", "card_last4", "payment_status"], payment_rows)


def gen_support_tickets(customer_ids, out_dir, n):
    rows = []
    for i in range(1, n + 1):
        cid = random.choice(customer_ids)
        opened = fake.date_time_between(start_date="-30d", end_date="now")
        closed = opened + timedelta(hours=random.randint(1, 72)) if random.random() < 0.8 else None
        rows.append([
            f"TCK{i:07d}", cid, opened.strftime("%Y-%m-%d %H:%M:%S"),
            closed.strftime("%Y-%m-%d %H:%M:%S") if closed else "",
            random.choice(TICKET_CATEGORIES), random.choice(["LOW", "MEDIUM", "HIGH", "URGENT"]),
            "CLOSED" if closed else "OPEN", random.choice(TICKET_CHANNELS),
        ])
    write_csv(f"{out_dir}/support_tickets/support_tickets_{datetime.now():%Y%m%d}.csv",
        ["ticket_id", "customer_id", "opened_at", "closed_at", "category",
         "priority", "ticket_status", "channel"], rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="./data_out")
    ap.add_argument("--customers", type=int, default=5000)
    ap.add_argument("--cdr-per-day", type=int, default=20000)
    ap.add_argument("--days", type=int, default=3)
    ap.add_argument("--tickets", type=int, default=800)
    args = ap.parse_args()

    print("Generating Running Telco synthetic source feeds...")
    gen_plans(args.out)
    customer_ids = gen_customers(args.customers, args.out)
    gen_devices(customer_ids, args.out)
    tower_ids = gen_towers(args.out)
    gen_cdr(customer_ids, tower_ids, args.out, args.cdr_per_day, args.days)
    gen_billing_and_payments(customer_ids, args.out)
    gen_support_tickets(customer_ids, args.out, args.tickets)
    print("Done. Files are laid out under --out matching the S3 prefix structure "
          "expected by the Snowflake external stages (see sql/00_setup/03_file_formats_stages.sql).")


if __name__ == "__main__":
    main()
