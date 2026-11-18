-- Only needed if you already ran an older setup.sql (before spores had a city).
-- Supabase dashboard → SQL Editor → New query → paste and Run.
alter table public.spores
  add column if not exists city    text check (char_length(city) <= 60),
  add column if not exists country text check (char_length(country) <= 60);
grant insert (city, country) on public.spores to authenticated;
