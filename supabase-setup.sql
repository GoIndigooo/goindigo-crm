-- ============================================================
-- GoIndigo CRM — Supabase Database Setup
-- Run this in the Supabase SQL Editor (in order)
-- ============================================================

-- ============================================================
-- SECTION 1: EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ============================================================
-- SECTION 2: TABLES
-- ============================================================

-- Profiles: extends Supabase auth.users
-- One row per user, auto-created on signup (see trigger below)
CREATE TABLE IF NOT EXISTS profiles (
  id          UUID        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name   TEXT,
  company     TEXT,
  role        TEXT        NOT NULL DEFAULT 'client', -- 'admin' | 'client'
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Leads: core pipeline records
CREATE TABLE IF NOT EXISTS leads (
  id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     UUID          NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  -- Contact info
  name          TEXT          NOT NULL,
  phone         TEXT,
  email         TEXT,
  address       TEXT,
  service       TEXT,         -- 'water' | 'mold' | 'fire' | 'storm' | 'other'
  description   TEXT,

  -- Pipeline
  stage         TEXT          NOT NULL DEFAULT 'new_lead',
  job_value     DECIMAL(10,2),

  -- Google Ads attribution
  gclid         TEXT,
  utm_source    TEXT          DEFAULT 'google',
  utm_medium    TEXT          DEFAULT 'cpc',
  utm_campaign  TEXT,
  utm_term      TEXT,
  utm_content   TEXT,

  -- Misc
  notes         TEXT,
  created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Stage history: audit trail and conversion tracking
CREATE TABLE IF NOT EXISTS stage_history (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id     UUID        NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  from_stage  TEXT,
  to_stage    TEXT        NOT NULL,
  job_value   DECIMAL(10,2),
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  changed_by  UUID        REFERENCES profiles(id)
);


-- ============================================================
-- SECTION 3: UPDATED_AT TRIGGER
-- Automatically bumps leads.updated_at on every row update
-- ============================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_leads_updated_at ON leads;
CREATE TRIGGER set_leads_updated_at
  BEFORE UPDATE ON leads
  FOR EACH ROW
  EXECUTE FUNCTION trigger_set_updated_at();


-- ============================================================
-- SECTION 4: AUTO-CREATE PROFILE ON SIGNUP
-- When a new user is created in auth.users, insert a matching
-- row in public.profiles automatically.
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, company, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'company', ''),
    COALESCE(NEW.raw_user_meta_data->>'role', 'client')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION handle_new_user();


-- ============================================================
-- SECTION 5: ROW-LEVEL SECURITY (RLS)
-- ============================================================

-- Enable RLS on all tables
ALTER TABLE profiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE leads        ENABLE ROW LEVEL SECURITY;
ALTER TABLE stage_history ENABLE ROW LEVEL SECURITY;


-- ── PROFILES ────────────────────────────────────────────────

-- Users can read their own profile
CREATE POLICY "profiles_select_own"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

-- Admins can read all profiles
CREATE POLICY "profiles_select_admin"
  ON profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

-- Users can update their own profile
CREATE POLICY "profiles_update_own"
  ON profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Allow insert (needed for the trigger function which runs as SECURITY DEFINER)
CREATE POLICY "profiles_insert_own"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() = id);


-- ── LEADS ────────────────────────────────────────────────────

-- Clients see only their own leads
CREATE POLICY "leads_select_own"
  ON leads FOR SELECT
  USING (client_id = auth.uid());

-- Admins see all leads
CREATE POLICY "leads_select_admin"
  ON leads FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

-- Clients can insert their own leads
CREATE POLICY "leads_insert_own"
  ON leads FOR INSERT
  WITH CHECK (client_id = auth.uid());

-- Clients can update their own leads; admins can update all
CREATE POLICY "leads_update_own"
  ON leads FOR UPDATE
  USING (
    client_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

-- Only admins can delete leads
CREATE POLICY "leads_delete_admin"
  ON leads FOR DELETE
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );


-- ── STAGE_HISTORY ────────────────────────────────────────────

-- Clients can see history for their own leads
CREATE POLICY "stage_history_select_own"
  ON stage_history FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM leads l
      WHERE l.id = stage_history.lead_id
        AND l.client_id = auth.uid()
    )
  );

-- Admins see all history
CREATE POLICY "stage_history_select_admin"
  ON stage_history FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );

-- Anyone can insert history for their own leads
CREATE POLICY "stage_history_insert_own"
  ON stage_history FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM leads l
      WHERE l.id = stage_history.lead_id
        AND l.client_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.role = 'admin'
    )
  );


-- ============================================================
-- SECTION 6: CONVERSION-READY LEADS FUNCTION
-- Returns leads that moved to job_won and have a gclid,
-- ready for Google Ads offline conversion import.
-- ============================================================

CREATE OR REPLACE FUNCTION get_conversion_ready_leads(requesting_user_id UUID DEFAULT auth.uid())
RETURNS TABLE (
  gclid           TEXT,
  conversion_name TEXT,
  conversion_time TEXT,
  conversion_value DECIMAL(10,2),
  currency        TEXT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    l.gclid,
    'JobWon'::TEXT                                          AS conversion_name,
    TO_CHAR(sh.changed_at AT TIME ZONE 'America/New_York',
            'YYYY-MM-DD HH24:MI:SS')                       AS conversion_time,
    sh.job_value,
    'USD'::TEXT                                             AS currency
  FROM stage_history sh
  JOIN leads l ON l.id = sh.lead_id
  WHERE sh.to_stage = 'job_won'
    AND l.gclid IS NOT NULL
    AND l.gclid <> ''
    AND (
      l.client_id = requesting_user_id
      OR EXISTS (
        SELECT 1 FROM profiles p
        WHERE p.id = requesting_user_id AND p.role = 'admin'
      )
    )
  ORDER BY sh.changed_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================
-- SECTION 7: INDEXES (performance)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_leads_client_id  ON leads(client_id);
CREATE INDEX IF NOT EXISTS idx_leads_stage       ON leads(stage);
CREATE INDEX IF NOT EXISTS idx_leads_created_at  ON leads(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stage_history_lead ON stage_history(lead_id);


-- ============================================================
-- SECTION 8: SAMPLE DATA (commented out — uncomment to test)
-- ============================================================

/*

-- Step 1: Create test users via Supabase Auth dashboard or API,
--         then use their UUIDs below.

-- Example profile updates (assumes users already exist in auth.users)
-- UPDATE profiles SET full_name='Jane Admin',  company='GoIndigo HQ',      role='admin'  WHERE id = 'YOUR-ADMIN-UUID';
-- UPDATE profiles SET full_name='Bob Client',  company='GoIndigo Tampa',    role='client' WHERE id = 'YOUR-CLIENT-1-UUID';
-- UPDATE profiles SET full_name='Sara Client', company='GoIndigo Orlando',  role='client' WHERE id = 'YOUR-CLIENT-2-UUID';

-- Sample leads for Bob Client
INSERT INTO leads (client_id, name, phone, email, address, service, description, stage, job_value, gclid, utm_source, utm_campaign)
VALUES
  ('YOUR-CLIENT-1-UUID', 'Mark Johnson',   '813-555-0101', 'mark@email.com',  '100 Oak St, Tampa FL',    'water', 'Burst pipe under kitchen sink', 'new_lead',           NULL,    NULL,                 'google', 'water-damage-tampa'),
  ('YOUR-CLIENT-1-UUID', 'Linda Park',     '813-555-0102', 'linda@email.com', '200 Pine Ave, Tampa FL',  'mold',  'Black mold in bathroom',        'contacted',          NULL,    'Cj0KCQjwtest1234',  'google', 'mold-removal-tampa'),
  ('YOUR-CLIENT-1-UUID', 'Chris Webb',     '813-555-0103', 'chris@email.com', '300 Elm Rd, Tampa FL',    'fire',  'Kitchen fire smoke damage',     'estimate_scheduled', NULL,    'Cj0KCQjwtest5678',  'google', 'fire-damage-tampa'),
  ('YOUR-CLIENT-1-UUID', 'Amy Torres',     '813-555-0104', 'amy@email.com',   '400 Maple Dr, Tampa FL',  'water', 'Roof leak water damage',        'job_won',            4500.00, 'Cj0KCQjwtest9012',  'google', 'water-damage-tampa'),
  ('YOUR-CLIENT-1-UUID', 'David Kim',      '813-555-0105', 'david@email.com', '500 Cedar Ln, Tampa FL',  'storm', 'Hurricane wind damage',         'job_complete',       8200.00, 'Cj0KCQjwtestABCD',  'google', 'storm-damage-tampa');

-- Sample leads for Sara Client
INSERT INTO leads (client_id, name, phone, email, address, service, description, stage, job_value, gclid, utm_source, utm_campaign)
VALUES
  ('YOUR-CLIENT-2-UUID', 'Emma Davis',     '407-555-0201', 'emma@email.com',  '10 Lake St, Orlando FL',  'water', 'Flooded basement',              'new_lead',           NULL,    NULL,                 'google', 'water-damage-orlando'),
  ('YOUR-CLIENT-2-UUID', 'Frank Wilson',   '407-555-0202', 'frank@email.com', '20 River Rd, Orlando FL', 'mold',  'Mold after flood',              'estimate_completed', NULL,    'Cj0KCQjwtestEFGH',  'google', 'mold-removal-orlando'),
  ('YOUR-CLIENT-2-UUID', 'Grace Lee',      '407-555-0203', 'grace@email.com', '30 Bay Blvd, Orlando FL', 'fire',  'Electrical fire',               'job_won',            6700.00, 'Cj0KCQjwtestIJKL',  'google', 'fire-damage-orlando'),
  ('YOUR-CLIENT-2-UUID', 'Henry Brown',    '407-555-0204', 'henry@email.com', '40 Hill Ave, Orlando FL', 'storm', 'Tree fell on roof',             'lost',               NULL,    NULL,                 'google', 'storm-damage-orlando'),
  ('YOUR-CLIENT-2-UUID', 'Iris Martin',    '407-555-0205', 'iris@email.com',  '50 Park Dr, Orlando FL',  'water', 'Pipe burst in wall',            'contacted',          NULL,    'Cj0KCQjwtestMNOP',  'google', 'water-damage-orlando');

*/

-- ============================================================
-- GoIndigo CRM setup complete!
-- Next steps:
-- 1. Your Supabase credentials are already set in index.html
-- 2. Create your admin user via Supabase Auth dashboard
-- 3. Run: UPDATE profiles SET role='admin', full_name='Daniel', company='GoIndigo HQ' WHERE id='YOUR-UUID';
-- ============================================================
