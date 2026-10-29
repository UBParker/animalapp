-- Voice milestone schema: animals, voice recordings, vocalizations and voice tags, mirroring the
-- SwiftData models field for field in snake_case, plus the sync columns and a private bucket for
-- the recorded audio.
--
-- Two timestamps, on two clocks, doing two different jobs:
--   updated_at        the device's clock. Last-write-wins is decided on this, on the device and
--                     again here in sync_row_guard().
--   server_updated_at the server's clock, set only by the trigger. Pulls page on this, so a row
--                     can never be missed because two devices disagree about what time it is.
--
-- animal_id and recording_id are plain uuid columns on purpose: sync pushes tables in an arbitrary
-- order, so a real foreign key would reject a child row that arrives before its parent.
--
-- The key is (user_id, id), not id. A global `id uuid primary key` would be unique across every
-- account, and the nineteen built-in voice tag ids are a fixed function of kind and name
-- (VoiceTagSeed.builtInID), so any install can compute them without being told. One account
-- inserting those nineteen ids under its own user_id would make every other account's tag push
-- fail forever: the upsert hits `on conflict ... do update`, the update policy is applied to the
-- squatter's row and refuses, and the write raises. The victim cannot see, fix or delete the row
-- that is blocking them. Per-user keying lets two accounts hold the same built-in id, which costs
-- nothing because no row is ever addressed without its owner. The pusher must match it and upsert
-- with on_conflict=user_id,id; the storage layer already keys objects the same way, as
-- "<user_id>/<file>".
--
-- `create table if not exists` means this key is only applied to a database that does not have
-- these tables yet. Changing the key of an already-applied table needs its own later migration.

create table if not exists public.animals (
    id uuid not null,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    name text not null default '',
    species text not null default '',
    color_hex text not null default '',
    photo_filename text,
    photo_thumbnail_filename text,
    tracks_outdoor_time boolean not null default true,
    sort_order integer not null default 0,
    is_archived boolean not null default false,
    note text,
    primary key (user_id, id)
);

create table if not exists public.voice_recordings (
    id uuid not null,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    animal_id uuid,
    recorded_at timestamptz not null default now(),
    duration_s double precision not null default 0,
    audio_filename text not null default '',
    status_raw text not null default 'recorded',
    error_message text,
    note text not null default '',
    activity_tag text,
    meaning_tag text,
    user_confidence integer,
    edited_at timestamptz,
    audio_uploaded_at timestamptz,
    primary key (user_id, id)
);

create table if not exists public.vocalizations (
    id uuid not null,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    recording_id uuid,
    start_s double precision not null default 0,
    end_s double precision not null default 0,
    f0_mean double precision,
    f0_min double precision,
    f0_max double precision,
    f0_slope double precision,
    voiced_fraction double precision not null default 0,
    rms_db double precision not null default -160,
    spectral_centroid_hz double precision not null default 0,
    mfcc double precision[] not null default '{}',
    activity_tag text,
    meaning_tag text,
    user_confidence integer,
    overridden boolean not null default false,
    primary key (user_id, id)
);

create table if not exists public.voice_tags (
    id uuid not null,
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    server_updated_at timestamptz not null default now(),
    deleted_at timestamptz,
    kind_raw text not null default 'activity',
    name text not null default '',
    is_built_in boolean not null default false,
    sort_order integer not null default 0,
    primary key (user_id, id)
);

-- Pull cursor: the exact ordering the app pages on, id last so the order is total and offset
-- paging inside one timestamp is stable.
create index if not exists animals_user_server_idx on public.animals (user_id, server_updated_at, id);
create index if not exists voice_recordings_user_server_idx on public.voice_recordings (user_id, server_updated_at, id);
create index if not exists vocalizations_user_server_idx on public.vocalizations (user_id, server_updated_at, id);
create index if not exists voice_tags_user_server_idx on public.voice_tags (user_id, server_updated_at, id);

-- ---------------------------------------------------------------------------
-- Server-side last write wins.
--
-- The device already resolves conflicts on updated_at, but two devices pushing at once can still
-- interleave so that the older write lands second. This trigger makes the rule hold whatever
-- order the requests arrive in, and makes a delete permanent.
--
-- Two things this trigger does not solve, recorded so they are not rediscovered as surprises:
--   * One function is shared by four tables and reads new.updated_at, new.deleted_at and
--     new.server_updated_at unqualified. Combined with `create table if not exists`, a table that
--     already exists in some other shape keeps that shape and then fails on every write instead of
--     failing once at migration time.
--   * Tombstone retention is undecided: rows with deleted_at set are kept forever. A later purge
--     must not simply delete them, because a device that has not pulled the tombstone yet would
--     re-insert the row on its next push.
-- ---------------------------------------------------------------------------

create or replace function public.sync_row_guard()
returns trigger
language plpgsql
-- Not security definer, so this is not an escalation fix. It is pinned anyway because it is one
-- line: a trigger runs under whatever search_path the caller set, and an unqualified name in a
-- future edit to this body would then resolve wherever that caller pointed it.
set search_path = public, pg_temp
as $$
begin
    -- A device clock that is wrong must not be able to freeze a row against every later edit.
    -- Without this, one row stamped in 2030 makes every genuine later edit fail the staleness
    -- test below, so the upsert returns success, the device advances its watermark, and the edit
    -- is silently discarded; worse, the next pull brings the 2030 row back down and overwrites
    -- the corrected local copy. A small forward tolerance absorbs ordinary skew; anything beyond
    -- it is clamped to the server's clock, which is the only clock both devices agree on.
    -- Runs before the INSERT branch so it covers both paths.
    new.updated_at := least(new.updated_at, now() + interval '5 minutes');

    if tg_op = 'INSERT' then
        new.server_updated_at := now();
        return new;
    end if;

    -- A delete is permanent. A later edit from a device that had not heard about it yet must not
    -- resurrect the row.
    -- Note the other end of this rule: a live row and a pending tombstone for the same id inside
    -- one batch is a duplicate key in a single statement, which Postgres raises as SQLSTATE 21000
    -- rather than collapsing, and that wedges the table's push until the batch is split.
    new.deleted_at := coalesce(old.deleted_at, new.deleted_at);

    -- Same or older device timestamp: this writer is replaying something already superseded.
    -- Return old, which leaves the row exactly as it is without raising, so a stale device sees a
    -- successful upsert and moves on rather than retrying forever.
    if new.updated_at <= old.updated_at then
        return old;
    end if;

    new.server_updated_at := now();
    return new;
end;
$$;

drop trigger if exists animals_sync_guard on public.animals;
create trigger animals_sync_guard before insert or update on public.animals
    for each row execute function public.sync_row_guard();

drop trigger if exists voice_recordings_sync_guard on public.voice_recordings;
create trigger voice_recordings_sync_guard before insert or update on public.voice_recordings
    for each row execute function public.sync_row_guard();

drop trigger if exists vocalizations_sync_guard on public.vocalizations;
create trigger vocalizations_sync_guard before insert or update on public.vocalizations
    for each row execute function public.sync_row_guard();

drop trigger if exists voice_tags_sync_guard on public.voice_tags;
create trigger voice_tags_sync_guard before insert or update on public.voice_tags
    for each row execute function public.sync_row_guard();

-- ---------------------------------------------------------------------------
-- Table privileges.
--
-- Privileges and row level security are independent, and privileges are checked first, so a role
-- with no grant is refused before a single policy is consulted: PostgREST returns
-- "42501 permission denied for table animals" and the whole sync path is dead. This block used to
-- be unnecessary, because Supabase ran `alter default privileges ... grant all` for anon,
-- authenticated and service_role on every new table. That is being withdrawn: opt-in from
-- 2026-04-28, default for new projects 2026-05-30, applied to existing projects on 2026-10-30.
-- https://github.com/orgs/supabase/discussions/45329
--
-- Granting explicitly gives up nothing. Row level security still decides which rows; the grant
-- only decides whether the role may reach the table at all. `anon` is deliberately not granted:
-- the app signs in before it syncs, and nothing here is readable without a user id.
--
-- No sequence grants are needed: every id is a client-supplied uuid and sort_order is a plain
-- integer with a constant default.
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.animals to authenticated;
grant select, insert, update, delete on public.voice_recordings to authenticated;
grant select, insert, update, delete on public.vocalizations to authenticated;
grant select, insert, update, delete on public.voice_tags to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security. Every verb, every table, scoped to authenticated callers, and
-- `(select auth.uid())` so the uid is evaluated once per statement rather than once per row.
-- ---------------------------------------------------------------------------

alter table public.animals enable row level security;
alter table public.voice_recordings enable row level security;
alter table public.vocalizations enable row level security;
alter table public.voice_tags enable row level security;

drop policy if exists animals_select_own on public.animals;
drop policy if exists animals_insert_own on public.animals;
drop policy if exists animals_update_own on public.animals;
drop policy if exists animals_delete_own on public.animals;
create policy animals_select_own on public.animals for select to authenticated
    using (user_id = (select auth.uid()));
create policy animals_insert_own on public.animals for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy animals_update_own on public.animals for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy animals_delete_own on public.animals for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists voice_recordings_select_own on public.voice_recordings;
drop policy if exists voice_recordings_insert_own on public.voice_recordings;
drop policy if exists voice_recordings_update_own on public.voice_recordings;
drop policy if exists voice_recordings_delete_own on public.voice_recordings;
create policy voice_recordings_select_own on public.voice_recordings for select to authenticated
    using (user_id = (select auth.uid()));
create policy voice_recordings_insert_own on public.voice_recordings for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy voice_recordings_update_own on public.voice_recordings for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy voice_recordings_delete_own on public.voice_recordings for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists vocalizations_select_own on public.vocalizations;
drop policy if exists vocalizations_insert_own on public.vocalizations;
drop policy if exists vocalizations_update_own on public.vocalizations;
drop policy if exists vocalizations_delete_own on public.vocalizations;
create policy vocalizations_select_own on public.vocalizations for select to authenticated
    using (user_id = (select auth.uid()));
create policy vocalizations_insert_own on public.vocalizations for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy vocalizations_update_own on public.vocalizations for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy vocalizations_delete_own on public.vocalizations for delete to authenticated
    using (user_id = (select auth.uid()));

drop policy if exists voice_tags_select_own on public.voice_tags;
drop policy if exists voice_tags_insert_own on public.voice_tags;
drop policy if exists voice_tags_update_own on public.voice_tags;
drop policy if exists voice_tags_delete_own on public.voice_tags;
create policy voice_tags_select_own on public.voice_tags for select to authenticated
    using (user_id = (select auth.uid()));
create policy voice_tags_insert_own on public.voice_tags for insert to authenticated
    with check (user_id = (select auth.uid()));
create policy voice_tags_update_own on public.voice_tags for update to authenticated
    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy voice_tags_delete_own on public.voice_tags for delete to authenticated
    using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Private bucket for the recorded audio. Objects live at "<user_id>/<audioFilename>".
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice-audio', 'voice-audio', false, 52428800, '{audio/mp4}')
on conflict (id) do update
    set public = excluded.public,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists voice_audio_select_own on storage.objects;
drop policy if exists voice_audio_insert_own on storage.objects;
drop policy if exists voice_audio_update_own on storage.objects;
drop policy if exists voice_audio_delete_own on storage.objects;
create policy voice_audio_select_own on storage.objects for select to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_insert_own on storage.objects for insert to authenticated
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_update_own on storage.objects for update to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy voice_audio_delete_own on storage.objects for delete to authenticated
    using (bucket_id = 'voice-audio' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------------------------------------------------------------------------
-- Account deletion. Security definer because a caller cannot delete their own auth.users row or
-- reach storage.objects outside their policies; search_path is pinned because a security definer
-- function with a caller-controlled search_path is a privilege escalation.
-- ---------------------------------------------------------------------------

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, storage, auth, pg_temp
as $$
declare
    uid uuid := auth.uid();
begin
    if uid is null then
        raise exception 'delete_my_account() requires an authenticated caller';
    end if;

    delete from storage.objects
     where bucket_id = 'voice-audio'
       and (storage.foldername(name))[1] = uid::text;

    delete from public.vocalizations where user_id = uid;
    delete from public.voice_recordings where user_id = uid;
    delete from public.voice_tags where user_id = uid;
    delete from public.animals where user_id = uid;

    -- The cascade on user_id would take the rows anyway; deleting them explicitly first means a
    -- failure here leaves nothing half-deleted behind an account that still exists.
    delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;
