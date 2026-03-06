# 🧾 Supplier Invoice Ingest – n8n Automation Workflow

![Status](https://img.shields.io/badge/status-complete-brightgreen)
![n8n](https://img.shields.io/badge/built%20with-n8n-orange)
![PostgreSQL](https://img.shields.io/badge/database-PostgreSQL-blue)
![Assessment](https://img.shields.io/badge/Blue%20Vision%20AI-Internship%20Assessment-purple)

---

**Author:** Nicolette Mashaba  
**Submitted for:** Blue Vision AI – AI Software Engineer Intern Assessment  
**Date:** March 2026

---

## Overview

This n8n workflow automates the ingestion of supplier invoice CSV files. It validates records against defined business rules, prevents duplicate inserts using database-level unique constraints, persists valid invoices to PostgreSQL, and delivers an HTML email summary after every run.

**Sources supported (Bonus: two sources):**
- Webhook upload (multipart POST) — primary trigger
- Google Drive folder watch — automatic trigger on new file

---

## Architecture

```
[Webhook / Google Drive]
         ↓
[Download File]
         ↓
[Generate SHA-256 Hash]  ← idempotency guard
         ↓
[Parse CSV → JSON]
         ↓
[Validate & Normalise Rows]
         ↓
    [Route: Valid?]
    /           \
[Valid]        [Failed → Mark status=failed]
   ↓
[Check Duplicate in DB]
    /           \
[New]         [Duplicate → Mark status=duplicate]
   ↓
[Insert → status=inserted]
         ↓
[Aggregate Metrics]
         ↓
[Send Email Summary]
```

---

## Prerequisites

- n8n (v1.x or later) — self-hosted or cloud
- PostgreSQL (v14+)
- Google account (for Drive trigger + Gmail email)
- Node.js `luxon` available in n8n Code nodes (included by default in n8n)

---

## Database Setup

### 1. Create the database and table

Connect to your PostgreSQL instance and run:

```sql
-- Create database (if needed)
CREATE DATABASE supplier_db;

-- Connect to it, then run:
CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- enables gen_random_uuid()

CREATE TABLE IF NOT EXISTS supplier_invoices (
  id                UUID         DEFAULT gen_random_uuid() PRIMARY KEY,
  invoice_number    TEXT         NOT NULL,
  supplier_number   TEXT         NOT NULL,
  supplier_name     TEXT         NOT NULL,
  department        TEXT         NOT NULL,
  amount_excl_vat   NUMERIC(12,2) NOT NULL,
  vat               NUMERIC(12,2) NOT NULL,
  amount_incl_vat   NUMERIC(12,2) NOT NULL,
  invoice_date      DATE         NOT NULL,
  source_file_name  TEXT,
  source_hash       TEXT,
  ingest_timestamp  TIMESTAMPTZ  DEFAULT now(),
  status            TEXT         CHECK (status IN ('inserted','duplicate','failed')) NOT NULL,
  validation_notes  TEXT,
  UNIQUE (supplier_number, invoice_number)
);

-- Optional: failure/retry table (Bonus)
CREATE TABLE IF NOT EXISTS supplier_invoices_failures (
  id               UUID         DEFAULT gen_random_uuid() PRIMARY KEY,
  invoice_number   TEXT,
  supplier_number  TEXT,
  raw_payload      JSONB,
  error_message    TEXT,
  retry_count      INT          DEFAULT 0,
  created_at       TIMESTAMPTZ  DEFAULT now()
);
```

### 2. Configure credentials in n8n

Go to **Settings → Credentials** and add:

| Credential Name         | Type       | Details                              |
|-------------------------|------------|--------------------------------------|
| Postgres – Supplier DB  | PostgreSQL | Host, port, database, user, password |
| Gmail – Alert Account   | Gmail OAuth2 | Authenticate with your Google account |
| Google Drive (optional) | Google Drive OAuth2 | For the Drive trigger bonus |

### 3. Set environment variables in n8n

In n8n Settings → Environment Variables (or `.env` file for self-hosted):

```
ALERT_EMAIL=your-alert-email@example.com
GDRIVE_FOLDER_ID=your-google-drive-folder-id
```

---

## Installing the Workflow

1. Open your n8n instance
2. Click **Workflows → Import from File**
3. Select `supplier-ingest.json`
4. Update credential references in these nodes:
   - `Check Duplicate in DB` → select **Postgres – Supplier DB**
   - `Insert Valid Invoice` → select **Postgres – Supplier DB**
   - `Send Email Summary` → select **Gmail – Alert Account**
   - `Google Drive Trigger` → select your Drive credential + set folder ID
5. Click **Save**, then **Activate**

---

## Triggers

### Trigger A – Webhook (Manual / Application Upload)

**Endpoint:** `POST /webhook/upload-invoice`

Send a multipart form request with the CSV file:

```bash
curl -X POST https://your-n8n-host/webhook/upload-invoice \
  -F "file=@supplier_batch.csv"
```

**Response:**
```json
{
  "status": "accepted",
  "message": "Invoice file received and is being processed.",
  "file": "supplier_batch.csv"
}
```

### Trigger B – Google Drive Folder Watch (Bonus)

1. Create a dedicated folder in Google Drive (e.g. `invoice-inbox`)
2. Copy the folder ID from the URL: `drive.google.com/drive/folders/FOLDER_ID_HERE`
3. Set `GDRIVE_FOLDER_ID` environment variable to that ID
4. Any new CSV file placed in that folder automatically triggers the workflow

---

## CSV Format

### Required Headers

```
supplier_number,supplier_name,invoice_number,department,invoice_date,amount_excl
```

### Optional Headers

```
vat_rate    (default: 15 if absent — South African standard VAT)
vat         (derived if absent: amount_excl × vat_rate / 100)
amount_incl (derived if absent: amount_excl + vat)
```

### Field Mapping

| CSV Header     | DB Column         | Notes                              |
|----------------|-------------------|------------------------------------|
| supplier_number| supplier_number   | Required, indexed                  |
| supplier_name  | supplier_name     | Required                           |
| invoice_number | invoice_number    | Required, indexed                  |
| department     | department        | Required                           |
| invoice_date   | invoice_date      | ISO format (YYYY-MM-DD), required  |
| amount_excl    | amount_excl_vat   | Required numeric                   |
| vat_rate       | *(used for calc)* | Optional, default 15               |
| vat            | vat               | Optional, derived if absent        |
| amount_incl    | amount_incl_vat   | Optional, derived if absent        |

### Sample CSV

```csv
supplier_number,supplier_name,invoice_number,department,invoice_date,amount_excl,vat_rate
S009,OfficeCo,OC-22119,Ops,2025-10-28,2175.00,15
S009,OfficeCo,OC-22120,Sales,2025-10-29,450.00,15
S011,PaperMart,PM-77891,Ops,2025-11-01,1020.00,15
S011,PaperMart,PM-77891,Ops,2025-11-01,1020.00,15
```

Row 4 is an intentional duplicate of Row 3 — it will be detected and skipped.

---

## Validation Logic

All validation runs in the **Validate & Normalise Rows** Code node.

### Rules Applied

| Rule | Logic | Error Message |
|------|-------|---------------|
| Required fields | `invoice_number`, `supplier_number`, `supplier_name`, `department`, `invoice_date`, `amount_excl` must be non-empty | `Missing {field_name}` |
| VAT math | `abs((amount_excl_vat + vat) - amount_incl_vat) <= 0.01` | `VAT math mismatch: ...` |
| VAT default | If `vat` absent, derive as `round(amount_excl × vat_rate / 100, 2)`. Default rate = 15% | *(silent fill)* |
| VAT rate check | If explicit `vat` differs from derived amount by > 0.01 | `VAT rate mismatch: ...` |
| Future date | `invoice_date` must not be after today (Africa/Johannesburg) | `invoice_date is in the future: ...` |
| Deduplication | `(supplier_number, invoice_number)` unique key checked against DB | `Duplicate: already exists` |

### Rounding Method

All amounts rounded to **2 decimal places** using JavaScript `toFixed(2)` (rounds half-up). This is applied at normalisation before validation checks.

### Timezone

All date comparisons use `Africa/Johannesburg` (UTC+2) via the `luxon` library's `DateTime.now().setZone('Africa/Johannesburg')`.

---

## Validation Examples

### Example 1 – Valid row (all fields present)
```
S009,OfficeCo,OC-22119,Ops,2025-10-28,2175.00,15
```
- VAT derived: `2175.00 × 15% = 326.25`
- amount_incl derived: `2175.00 + 326.25 = 2501.25`
- Date: `2025-10-28` — not in future ✅
- **Result:** `status=inserted`

### Example 2 – Duplicate row
```
S011,PaperMart,PM-77891,Ops,2025-11-01,1020.00,15
```
(Submitted a second time with identical supplier_number + invoice_number)
- **Result:** `status=duplicate`, skipped

### Example 3 – Future date
```
S012,TestCo,TC-99999,IT,2027-01-01,500.00,15
```
- **Result:** `status=failed`, `validation_notes=invoice_date is in the future: 2027-01-01`

### Example 4 – Missing required field
```
,OfficeCo,OC-00001,Finance,2025-09-15,800.00,15
```
- **Result:** `status=failed`, `validation_notes=Missing supplier_number`

---

## Email Alert

### Subject format
```
Supplier Ingest: 3 ok, 1 dup, 0 failed
```

### Body
An HTML email with:
- Summary table (Processed / Inserted / Duplicates / Failed)
- Error/issue table listing each problem row with invoice_number, supplier_number, and reason (capped at 20 rows)

### Configuration
- Node: `Send Email Summary`
- Credential: **Gmail – Alert Account**
- Recipient: set via `ALERT_EMAIL` environment variable
- Format: HTML

---

## Expected Results for Sample CSV

| Row | invoice_number | supplier_number | status    | validation_notes                        |
|-----|----------------|-----------------|-----------|------------------------------------------|
| 1   | OC-22119       | S009            | inserted  |                                          |
| 2   | OC-22120       | S009            | inserted  |                                          |
| 3   | PM-77891       | S011            | inserted  |                                          |
| 4   | PM-77891       | S011            | duplicate | Duplicate: already exists in supplier_invoices |

**Email subject:** `Supplier Ingest: 3 ok, 1 dup, 0 failed`

---

## Bonus Features Implemented

| Bonus Item | Status | Details |
|------------|--------|---------|
| Second source (Google Drive) | ✅ | Drive Trigger watches a folder; downloads file on creation |
| Failure table | ✅ | `supplier_invoices_failures` schema provided |
| Dry-run / staging | Schema provided | Set `DRY_RUN=true` env var and route inserts to `supplier_invoices_staging` |

---

## Error Handling

- **Invalid rows:** routed to `Mark as Failed` node; captured in metrics; included in email
- **Duplicate rows:** detected via DB query; routed to `Mark as Duplicate`; included in email summary
- **Node-level errors:** n8n's built-in error output pins can be connected to an Error Email node — configure under workflow settings → Error Workflow

---

## File Structure

```
submission/
├── supplier-ingest.json     # n8n workflow export (import directly into n8n)
├── README.md                # This file
├── schema.sql               # PostgreSQL table creation script
└── results.csv              # Sample run results for provided test data
```

---

## Quick Start Checklist

- [ ] Create PostgreSQL database and run `schema.sql`
- [ ] Add Postgres credential in n8n
- [ ] Add Gmail OAuth2 credential in n8n
- [ ] Set `ALERT_EMAIL` environment variable
- [ ] Import `supplier-ingest.json` into n8n
- [ ] Update credential references in DB and Gmail nodes
- [ ] Activate workflow
- [ ] Test: `curl -X POST /webhook/upload-invoice -F "file=@supplier_batch.csv"`
- [ ] Check database and email for results