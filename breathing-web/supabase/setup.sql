-- The Fermentary (Growing organism) — Supabase setup
-- Supabase dashboard → SQL Editor → New query → paste this whole file and Run.
-- You only need to run it once.

------------------------------------------------------------
-- 1. Tables
------------------------------------------------------------

-- Spores: each fermentation photo people upload
create table public.spores (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text not null check (char_length(title) between 1 and 60),
  body        text not null default '' check (char_length(body) <= 4000),
  who         text not null default 'Anonymous' check (char_length(who) between 1 and 30),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  city        text check (char_length(city) <= 60),
  country     text check (char_length(country) <= 60),
  img_path    text not null check (char_length(img_path) <= 200),
  thumb_path  text not null check (char_length(thumb_path) <= 200),
  energy      real not null default 2,
  born        timestamptz not null default now(),
  last_fed    timestamptz not null default now()
);

-- Comments: food given to a spore
create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  spore_id    uuid not null references public.spores(id) on delete cascade,
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  who         text not null default 'Anonymous' check (char_length(who) between 1 and 30),
  text        text not null default '' check (char_length(text) <= 2000),
  img_path    text check (char_length(img_path) <= 200),
  created_at  timestamptz not null default now(),
  check (char_length(text) > 0 or img_path is not null)
);
create index comments_spore_idx on public.comments (spore_id, created_at);

-- Hyphae: links between spores (sorted so a < b, one row per pair)
create table public.hyphae (
  id          uuid primary key default gen_random_uuid(),
  a           uuid not null references public.spores(id) on delete cascade,
  b           uuid not null references public.spores(id) on delete cascade,
  strength    int not null default 1,
  created_at  timestamptz not null default now(),
  check (a < b),
  unique (a, b)
);

-- Activity log: used to compute the whole site's "temperature"
create table public.activity (
  id          bigint generated always as identity primary key,
  kind        text not null,
  spore_id    uuid references public.spores(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index activity_time_idx on public.activity (created_at);

------------------------------------------------------------
-- 2. Growth rules (computed on the server so clients can't tamper with energy)
------------------------------------------------------------

create function public.log_activity(k text, s uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.activity where created_at < now() - interval '7 days';
  insert into public.activity (kind, spore_id) values (k, s);
$$;
revoke execute on function public.log_activity(text, uuid) from public, anon, authenticated;

-- New spore: force values + round location to ~100 m (privacy)
create function public.spores_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  new.owner    := auth.uid();
  new.energy   := 2;
  new.born     := now();
  new.last_fed := now();
  new.lat      := round(new.lat::numeric, 3);
  new.lng      := round(new.lng::numeric, 3);
  if new.img_path not like auth.uid()::text || '/%'
     or new.thumb_path not like auth.uid()::text || '/%' then
    raise exception 'photo must be in your own folder';
  end if;
  return new;
end $$;
create trigger spores_before_insert before insert on public.spores
  for each row execute function public.spores_before_insert();

create function public.spores_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.log_activity('spore', new.id);
  return null;
end $$;
create trigger spores_after_insert after insert on public.spores
  for each row execute function public.spores_after_insert();

-- Comment = food: text +3, photo +5, wakes it from dormancy
create function public.comments_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  new.owner      := auth.uid();
  new.created_at := now();
  if new.img_path is not null and new.img_path not like auth.uid()::text || '/%' then
    raise exception 'photo must be in your own folder';
  end if;
  return new;
end $$;
create trigger comments_before_insert before insert on public.comments
  for each row execute function public.comments_before_insert();

create function public.comments_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.spores
     set energy = energy + case when new.img_path is null then 3 else 5 end,
         last_fed = now()
   where id = new.spore_id;
  perform public.log_activity('comment', new.spore_id);
  return null;
end $$;
create trigger comments_after_insert after insert on public.comments
  for each row execute function public.comments_after_insert();

-- Linking: a new hypha gives both +2; an existing one thickens and gives both +1
create function public.connect_spores(x uuid, y uuid) returns public.hyphae
language plpgsql security definer set search_path = '' as $$
declare
  lo uuid := least(x, y);
  hi uuid := greatest(x, y);
  h  public.hyphae;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if x = y then raise exception 'cannot connect a spore to itself'; end if;
  insert into public.hyphae as hy (a, b) values (lo, hi)
    on conflict (a, b) do update set strength = hy.strength + 1
    returning * into h;
  update public.spores
     set energy = energy + case when h.strength = 1 then 2 else 1 end,
         last_fed = now()
   where id in (lo, hi);
  perform public.log_activity('link', lo);
  return h;
end $$;
revoke execute on function public.connect_spores(uuid, uuid) from public, anon;
grant execute on function public.connect_spores(uuid, uuid) to authenticated;

------------------------------------------------------------
-- 3. Permissions: anyone reads, signed-in users (incl. anonymous) write, you delete only your own
------------------------------------------------------------

grant usage on schema public to anon, authenticated;
grant select on public.spores, public.comments, public.hyphae, public.activity to anon, authenticated;
grant insert (title, body, who, lat, lng, city, country, img_path, thumb_path) on public.spores to authenticated;
grant insert (spore_id, who, text, img_path) on public.comments to authenticated;
grant delete on public.spores, public.comments to authenticated;

alter table public.spores   enable row level security;
alter table public.comments enable row level security;
alter table public.hyphae   enable row level security;
alter table public.activity enable row level security;

create policy "anyone can see spores"   on public.spores   for select to anon, authenticated using (true);
create policy "anyone can see comments" on public.comments for select to anon, authenticated using (true);
create policy "anyone can see hyphae"   on public.hyphae   for select to anon, authenticated using (true);
create policy "anyone can see activity" on public.activity for select to anon, authenticated using (true);

create policy "plant your own spore"  on public.spores   for insert to authenticated with check (owner = (select auth.uid()));
create policy "feed with a comment"   on public.comments for insert to authenticated with check (owner = (select auth.uid()));
create policy "remove your own spore" on public.spores   for delete to authenticated using (owner = (select auth.uid()));
create policy "remove your own comment" on public.comments for delete to authenticated using (owner = (select auth.uid()));

------------------------------------------------------------
-- 4. Photo storage: public read, upload only into your own folder (max 2 MB)
------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 2097152, array['image/jpeg', 'image/webp', 'image/png'])
on conflict (id) do nothing;

create policy "upload into your own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "delete from your own folder" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = (select auth.uid())::text);

------------------------------------------------------------
-- 5. Realtime: when someone feeds a spore, it grows on everyone's screen at once
------------------------------------------------------------

alter publication supabase_realtime add table public.spores, public.comments, public.hyphae, public.activity;
