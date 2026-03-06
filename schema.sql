-- ============================================================
-- Supplier Invoice Ingest – Database Schema
-- Author: Nicolette Mashaba
-- Blue Vision AI Internship Assessment
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- Main table: supplier_invoices
-- ============================================================
CREATE TABLE IF NOT EXISTS supplier_invoices (
    id                UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number    TEXT          NOT NULL,
    supplier_number   TEXT          NOT NULL,
    supplier_name     TEXT          NOT NULL,
    department        TEXT          NOT NULL,
    amount_excl_vat   NUMERIC(12,2) NOT NULL,
    vat               NUMERIC(12,2) NOT NULL,
    amount_incl_vat   NUMERIC(12,2) NOT NULL,
    invoice_date      DATE          NOT NULL,
    source_file_name  TEXT,
    source_hash       TEXT,
    ingest_timestamp  TIMESTAMPTZ   DEFAULT now(),
    status            TEXT          CHECK (status IN ('inserted', 'duplicate', 'failed')) NOT NULL,
    validation_notes  TEXT,
    -- Composite unique key: prevents duplicate (supplier, invoice) pairs
    UNIQUE (supplier_number, invoice_number)
);

-- Indexes for fast deduplication lookups
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_supplier_number ON supplier_invoices (supplier_number);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_invoice_number  ON supplier_invoices (invoice_number);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_status          ON supplier_invoices (status);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_source_hash     ON supplier_invoices (source_hash);

-- ============================================================
-- Bonus: Failures / retry table
-- ============================================================
CREATE TABLE IF NOT EXISTS supplier_invoices_failures (
    id              UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number  TEXT,
    supplier_number TEXT,
    raw_payload     JSONB,
    error_message   TEXT,
    retry_count     INT         DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT now(),
    last_retry_at   TIMESTAMPTZ
);

-- ============================================================
-- Bonus: Staging table for dry-run mode
-- Same structure as supplier_invoices, no unique constraint
-- ============================================================
CREATE TABLE IF NOT EXISTS supplier_invoices_staging (
    id                UUID          DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_number    TEXT,
    supplier_number   TEXT,
    supplier_name     TEXT,
    department        TEXT,
    amount_excl_vat   NUMERIC(12,2),
    vat               NUMERIC(12,2),
    amount_incl_vat   NUMERIC(12,2),
    invoice_date      DATE,
    source_file_name  TEXT,
    source_hash       TEXT,
    ingest_timestamp  TIMESTAMPTZ   DEFAULT now(),
    status            TEXT,
    validation_notes  TEXT
);

-- ============================================================
-- Verify setup
-- ============================================================
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN (
    'supplier_invoices',
    'supplier_invoices_failures',
    'supplier_invoices_staging'
  );