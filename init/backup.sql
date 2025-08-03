--
-- PostgreSQL database dump
--

-- Dumped from database version 15.13 (Debian 15.13-1.pgdg120+1)
-- Dumped by pg_dump version 15.13 (Debian 15.13-1.pgdg120+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: relationship_type_enum; Type: TYPE; Schema: public; Owner: registry_user
--

CREATE TYPE public.relationship_type_enum AS ENUM (
    'mother',
    'father',
    'spouse',
    'sibling',
    'guardian',
    'child',
    'partner',
    'grandparent',
    'other'
);


ALTER TYPE public.relationship_type_enum OWNER TO registry_user;

--
-- Name: backfill_family_links_from_events(); Type: FUNCTION; Schema: public; Owner: registry_user
--

CREATE FUNCTION public.backfill_family_links_from_events() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- 👶 Birth: child → mother/father
  INSERT INTO family_link (
    person_id,
    related_person_id,
    relationship_type,
    source_event_id,
    source,
    notes
  )
  SELECT DISTINCT ON (
    child.person_id, parent.person_id, parent.role, e.id
  )
    child.person_id,
    parent.person_id,
    CASE parent.role
      WHEN 'mother' THEN 'mother'
      WHEN 'father' THEN 'father'
    END::relationship_type_enum,
    e.id,
    'OpenCRVS',
    'Backfilled from birth event'
  FROM event e
  JOIN (
    SELECT DISTINCT event_id, person_id, role
    FROM event_participant
    WHERE role = 'subject'
  ) child ON child.event_id = e.id
  JOIN (
    SELECT DISTINCT event_id, person_id, role
    FROM event_participant
    WHERE role IN ('mother', 'father')
  ) parent ON parent.event_id = e.id
  LEFT JOIN family_link existing ON
    existing.person_id = child.person_id AND
    existing.related_person_id = parent.person_id AND
    existing.relationship_type = CASE parent.role
      WHEN 'mother' THEN 'mother'
      WHEN 'father' THEN 'father'
    END::relationship_type_enum AND
    existing.source_event_id = e.id
  WHERE e.event_type = 'birth'
    AND existing.id IS NULL
    AND parent.person_id IS NOT NULL
    AND child.person_id IS NOT NULL
    AND child.person_id != parent.person_id;

  -- 💍 Marriage: spouse ↔ spouse
  INSERT INTO family_link (
    person_id,
    related_person_id,
    relationship_type,
    source_event_id,
    source,
    notes
  )
  SELECT DISTINCT ON (a.person_id, b.person_id, e.id)
    a.person_id,
    b.person_id,
    'spouse'::relationship_type_enum,
    e.id,
    'OpenCRVS',
    'Backfilled from marriage event'
  FROM event e
  JOIN (
    SELECT DISTINCT event_id, person_id FROM event_participant WHERE role = 'groom'
  ) a ON a.event_id = e.id
  JOIN (
    SELECT DISTINCT event_id, person_id FROM event_participant WHERE role = 'bride'
  ) b ON b.event_id = e.id
  LEFT JOIN family_link existing ON
    existing.person_id = a.person_id AND
    existing.related_person_id = b.person_id AND
    existing.relationship_type = 'spouse' AND
    existing.source_event_id = e.id
  WHERE e.event_type = 'marriage'
    AND existing.id IS NULL
    AND a.person_id IS NOT NULL
    AND b.person_id IS NOT NULL
    AND a.person_id != b.person_id;

  RAISE NOTICE '✅ Family link backfill complete.';
END;
$$;


ALTER FUNCTION public.backfill_family_links_from_events() OWNER TO registry_user;

--
-- Name: create_family_link_from_event(); Type: FUNCTION; Schema: public; Owner: registry_user
--

CREATE FUNCTION public.create_family_link_from_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  child_id UUID;
BEGIN
  IF NEW.role IN ('mother', 'father') THEN
    -- Look for the child (role='subject' and type='child')
    SELECT person_id INTO child_id
    FROM event_participant
    WHERE event_id = NEW.event_id
      AND relationship_details->>'type' = 'child'
    LIMIT 1;

    IF child_id IS NOT NULL THEN
      -- Insert child → parent with correct direction
      IF NOT EXISTS (
        SELECT 1 FROM family_link
        WHERE person_id = child_id
          AND related_person_id = NEW.person_id
          AND relationship_type = NEW.role::relationship_type_enum
          AND source_event_id = NEW.event_id
      ) THEN
        INSERT INTO family_link (
          person_id,               -- child
          related_person_id,       -- mother or father
          relationship_type,
          source_event_id,
          start_date,
          end_date,
          source,
          notes
        )
        VALUES (
          child_id,
          NEW.person_id,
          NEW.role::relationship_type_enum,
          NEW.event_id,
          NULL, NULL,
          'event_participant',
          'Auto-linked from event'
        );
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.create_family_link_from_event() OWNER TO registry_user;

--
-- Name: create_reverse_family_link(); Type: FUNCTION; Schema: public; Owner: registry_user
--

CREATE FUNCTION public.create_reverse_family_link() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  reverse_type relationship_type_enum;
BEGIN
  CASE NEW.relationship_type
    WHEN 'mother' THEN reverse_type := 'child';
    WHEN 'father' THEN reverse_type := 'child';
    WHEN 'spouse' THEN reverse_type := 'spouse';
    WHEN 'sibling' THEN reverse_type := 'sibling';
    WHEN 'partner' THEN reverse_type := 'partner';
    ELSE
      -- Skip reverse creation for 'child' or undefined relationships
      RETURN NEW;
  END CASE;

  -- Check for duplicates
  IF NOT EXISTS (
    SELECT 1 FROM family_link
    WHERE person_id = NEW.related_person_id
      AND related_person_id = NEW.person_id
      AND relationship_type = reverse_type
      AND source_event_id = NEW.source_event_id
  ) THEN
    INSERT INTO family_link (
      person_id,
      related_person_id,
      relationship_type,
      relationship_subtype,
      source_event_id,
      start_date,
      end_date,
      source,
      notes
    )
    VALUES (
      NEW.related_person_id,
      NEW.person_id,
      reverse_type,
      NEW.relationship_subtype,
      NEW.source_event_id,
      NEW.start_date,
      NEW.end_date,
      NEW.source,
      'Auto-created reverse link'
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.create_reverse_family_link() OWNER TO registry_user;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: event; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.event (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    event_type text NOT NULL,
    event_date date,
    location text,
    source text,
    metadata jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    crvs_event_uuid uuid NOT NULL,
    duplicates uuid[],
    status text,
    last_update_at timestamp without time zone,
    remarks text
);


ALTER TABLE public.event OWNER TO registry_user;

--
-- Name: event_participant; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.event_participant (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid,
    event_id uuid,
    role text NOT NULL,
    relationship_details jsonb,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    crvs_person_id uuid,
    status text DEFAULT 'active'::text,
    ended_at timestamp without time zone,
    remarks text
);


ALTER TABLE public.event_participant OWNER TO registry_user;

--
-- Name: COLUMN event_participant.event_id; Type: COMMENT; Schema: public; Owner: registry_user
--

COMMENT ON COLUMN public.event_participant.event_id IS 'event_id → event.id ';


--
-- Name: family_link; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.family_link (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid NOT NULL,
    related_person_id uuid NOT NULL,
    relationship_type public.relationship_type_enum NOT NULL,
    relationship_subtype text,
    source_event_id uuid,
    start_date date,
    end_date date,
    source text DEFAULT 'OpenCRVS'::text,
    notes text,
    CONSTRAINT family_link_check CHECK ((person_id <> related_person_id))
);


ALTER TABLE public.family_link OWNER TO registry_user;

--
-- Name: get_family; Type: VIEW; Schema: public; Owner: registry_user
--

CREATE VIEW public.get_family AS
 SELECT f.person_id,
    f.relationship_type,
    json_agg(json_build_object('related_person_id', f.related_person_id, 'subtype', f.relationship_subtype, 'start_date', f.start_date, 'end_date', f.end_date, 'source_event_id', f.source_event_id)) AS relatives
   FROM public.family_link f
  GROUP BY f.person_id, f.relationship_type;


ALTER TABLE public.get_family OWNER TO registry_user;

--
-- Name: person; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.person (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    given_name text NOT NULL,
    family_name text NOT NULL,
    full_name text GENERATED ALWAYS AS (((given_name || ' '::text) || family_name)) STORED,
    gender text NOT NULL,
    dob date,
    place_of_birth text,
    identifiers jsonb,
    status text DEFAULT 'active'::text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    death_date date,
    CONSTRAINT person_gender_check CHECK ((gender = ANY (ARRAY['male'::text, 'female'::text, 'other'::text, 'unknown'::text])))
);


ALTER TABLE public.person OWNER TO registry_user;

--
-- Name: person_id_mapping; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.person_id_mapping (
    person_id uuid NOT NULL,
    external_person_id uuid NOT NULL,
    source text DEFAULT 'OpenCRVS'::text,
    linked_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.person_id_mapping OWNER TO registry_user;

--
-- Name: person_name_history; Type: TABLE; Schema: public; Owner: registry_user
--

CREATE TABLE public.person_name_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    person_id uuid NOT NULL,
    given_name text NOT NULL,
    family_name text NOT NULL,
    full_name text GENERATED ALWAYS AS (((given_name || ' '::text) || family_name)) STORED,
    change_reason text,
    valid_from date,
    valid_to date,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.person_name_history OWNER TO registry_user;

--
-- Data for Name: event; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.event (id, event_type, event_date, location, source, metadata, created_at, crvs_event_uuid, duplicates, status, last_update_at, remarks) FROM stdin;
3e5782a1-edf9-454c-bb7c-4e2a2a38b5f8	birth	1988-03-10	Lake Victor	seed	{"note": "generated birth"}	2025-05-13 15:29:42.659041	76141fb4-a2a9-45cc-9eda-78efaca2b919	\N	\N	\N	\N
b9ea837f-bee8-427c-ba76-d85547ee1121	birth	2007-10-24	West Donald	seed	{"note": "generated birth"}	2025-05-13 15:29:42.666826	c00d69e9-5f27-449d-8fde-bcd19cbca543	\N	\N	\N	\N
0af4e53c-16d0-43db-9c06-a90243ed44f6	birth	2021-10-06	Juliechester	seed	{"note": "generated birth"}	2025-05-13 15:29:42.670525	932f1428-e199-43e5-8060-6547989aa614	\N	\N	\N	\N
446b89ad-e88f-43af-88a5-4b880df3f0ac	birth	1999-09-21	Jeffreyberg	seed	{"note": "generated birth"}	2025-05-13 15:29:42.673985	6b2803d9-994c-4b91-b514-110bc1cb2a51	\N	\N	\N	\N
d96a7fee-922f-402d-b209-04f87e9afa20	birth	2014-09-16	Daviston	seed	{"note": "generated birth"}	2025-05-13 15:29:42.678306	6d1b57d4-9b7b-4279-ae5a-beb047b454bc	\N	\N	\N	\N
cf4562d4-8117-485b-9db3-1bf5778386c1	birth	1960-04-14	Lake Ernest	seed	{"note": "generated birth"}	2025-05-13 15:29:42.683974	bd075941-3c00-4766-906e-67853c40b5ff	\N	\N	\N	\N
9a232eb2-cf8f-45c8-92f3-d5d09745b92c	birth	2002-10-26	South Patrickmouth	seed	{"note": "generated birth"}	2025-05-13 15:29:42.687634	91be281e-5b8c-418d-9535-bbeeb07e7c02	\N	\N	\N	\N
3ab85b56-3084-48e9-ad1b-37ffbad0e9c8	birth	2017-05-17	Tashatown	seed	{"note": "generated birth"}	2025-05-13 15:29:42.691367	6b54ba26-29c8-4572-a7a8-dc70b1f17dff	\N	\N	\N	\N
e0efdc26-2ab8-489f-8b22-04286f677fd8	birth	1960-12-14	Kaylamouth	seed	{"note": "generated birth"}	2025-05-13 15:29:42.69556	5a9ab0ef-d072-403b-a768-c749873dd663	\N	\N	\N	\N
c7f0fef5-e3f1-42f2-8ecc-1c0ecac47f18	birth	1960-07-18	Ryanmouth	seed	{"note": "generated birth"}	2025-05-13 15:29:42.699477	5650fda4-0d5a-4e01-b304-04d16b33637e	\N	\N	\N	\N
582f0314-5cfe-49c6-bc93-341b169eaa0d	birth	1945-10-21	Teresaburgh	seed	{"note": "generated birth"}	2025-05-13 15:29:42.704422	e8875833-870f-4dc1-8afb-decd39babeb8	\N	\N	\N	\N
cf1ce9a3-95d2-4056-8422-ffe57d2a9a2d	birth	2014-06-16	Port Colleenhaven	seed	{"note": "generated birth"}	2025-05-13 15:29:42.709433	2f3e5ff4-a52f-476c-bd56-69d1796293e9	\N	\N	\N	\N
5f99a846-fbb5-44d1-9e91-6fdeec7fe82d	birth	1972-06-07	West Kathryn	seed	{"note": "generated birth"}	2025-05-13 15:29:42.716434	db950a81-26aa-4915-8e68-f9052ec871b2	\N	\N	\N	\N
1c8a7f44-5cc2-4d62-a80c-2a648fb42a81	birth	2018-10-09	New Mariotown	seed	{"note": "generated birth"}	2025-05-13 15:29:42.720042	03183b2c-05a5-4fd8-89b8-47fbf0d44fc5	\N	\N	\N	\N
38993fa5-93fc-4705-8676-29f8ddddfcaa	birth	1960-08-02	Natashaport	seed	{"note": "generated birth"}	2025-05-13 15:29:42.723942	e91151d9-dbc6-4c8e-9d66-f04b1162f756	\N	\N	\N	\N
072eacc6-f8c9-47b6-9046-195901ef1889	birth	1977-12-14	East Natalieland	seed	{"note": "generated birth"}	2025-05-13 15:29:42.730859	0c1b5237-6a7c-4bfe-88c6-2f08fdf99271	\N	\N	\N	\N
48850dee-d917-4437-8969-2932d9b7dc64	birth	1957-01-07	Cabreraside	seed	{"note": "generated birth"}	2025-05-13 15:29:42.740337	94743f17-cb32-44d8-8b38-05827a930f36	\N	\N	\N	\N
70e25861-002d-484e-9c20-81bb102c1991	birth	1962-06-24	Lake Thomas	seed	{"note": "generated birth"}	2025-05-13 15:29:42.7452	1de8d276-d77b-4aaf-a9bd-56fd38f2b1f5	\N	\N	\N	\N
1de479b6-a655-402b-bfee-019e740421d3	birth	2020-03-10	West Allison	seed	{"note": "generated birth"}	2025-05-13 15:29:42.751445	0b1270ed-8f05-4ad5-92a4-f844c8b714bc	\N	\N	\N	\N
72052043-1c32-4b4d-a27b-e38f77982e83	birth	2002-12-14	New Karina	seed	{"note": "generated birth"}	2025-05-13 15:29:42.755502	a9992f78-e0ad-4527-92e2-89ae1670a998	\N	\N	\N	\N
5a8ec55f-0693-4e0b-b6c9-2a78bfb16f3e	death	2017-04-03	Lake Joshuabury	seed	{"note": "added synthetic death"}	2025-05-13 16:02:51.939777	8a686425-3fbc-436f-9227-8f840f0affad	\N	\N	\N	\N
044e6a3c-2c6a-4527-bb2b-260c760d7d05	death	2017-09-26	Lake Joyside	seed	{"note": "added synthetic death"}	2025-05-13 16:02:51.944973	7b04abbc-9038-4ecf-b820-052e1679f7f3	\N	\N	\N	\N
89d3432e-98ad-4f43-b2f8-908368a1e601	death	2016-11-03	Johnsonland	seed	{"note": "added synthetic death"}	2025-05-13 16:02:51.949141	bd2a37f1-b7cd-4b63-bfca-498e51da4ef5	\N	\N	\N	\N
91edd78b-8658-4774-a486-081582e8eb70	death	2019-01-30	New Carolyn	seed	{"note": "added synthetic death"}	2025-05-13 16:02:51.953599	38004674-a0f7-4f6a-9e88-509f26f2f3ba	\N	\N	\N	\N
8fb08553-093c-4009-bb7d-5264faa11e25	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-06 13:51:36.378977	87268244-099f-43fa-ab62-0e5a4302b023	\N	\N	\N	\N
e8d2e3c8-a603-4471-aea9-4dfa7fb65bce	birth	2025-05-01	Unknown, FAR	OpenCRVS	{"trackingId": "BLOVXX0"}	2025-06-04 12:01:44.828288	399779e7-79e6-41b7-b368-9055cd704de3	{0f2c944e-e19b-42b9-8b1b-6bdf7585efe9}	DECLARED	2025-06-04 11:48:46.854	\N
1e83741c-84bb-4d7d-a00a-5581a5d8490e	birth	2025-05-01	Unknown, FAR	OpenCRVS	{"trackingId": "BWLNXIV"}	2025-06-04 10:59:57.515136	6e6eaca1-b689-4959-a256-1fb400793795	\N	ISSUED	2025-06-04 12:02:15.973	\N
42ac5713-2ebc-469c-92d1-15bc43da7e86	birth	2025-05-24	Town, FAR	OpenCRVS	{"trackingId": "BHQJ4LW"}	2025-06-02 19:35:42.947557	2f12bbbd-f370-4329-b9fc-74fdafe6fb2f	\N	REGISTERED	2025-06-04 12:02:58.016	\N
0f2c944e-e19b-42b9-8b1b-6bdf7585efe9	birth	2025-05-01	Health Institution, Fikombo HP	OpenCRVS	{"trackingId": "BR8ICR5"}	2025-05-29 13:12:45.397494	2810b4ae-2b8a-4a18-abff-258e21ccb35e	\N	REGISTERED	2025-06-04 12:03:36.369	\N
f518405d-b545-4a4a-a379-586da42470c3	birth	2025-05-01	Town, FAR	OpenCRVS	{"trackingId": "BYDEB70"}	2025-06-06 13:51:40.867351	f74783d8-2d43-4a10-9893-e61ff8d8ac9c	\N	\N	\N	\N
49acae79-040b-4ef4-95bb-ec67808f6ffe	birth	2025-06-01	Town, FAR	OpenCRVS	{"trackingId": "BRUWXNY"}	2025-06-02 11:08:34.875302	54581a02-0e69-44ff-a5d4-1b75e80a26ec	\N	REGISTERED	2025-06-04 12:05:39.841	\N
2d5e4536-80e1-4840-b456-5039c9e97882	birth	2025-05-28	Town, FAR	OpenCRVS	{"trackingId": "BWHUBJ1"}	2025-06-02 11:22:28.170174	bc8114d3-1e8d-47db-a179-d3a63ccb73cc	\N	REGISTERED	2025-06-04 12:06:20.431	\N
47ff409a-a403-4a5e-821f-9a7bab4fbe56	birth	2024-05-03	Town, FAR	OpenCRVS	{"trackingId": "BI26CR3"}	2025-06-02 11:50:10.041583	207c8697-4120-458b-9cff-112c904c3162	\N	REGISTERED	2025-06-04 12:07:11.61	\N
4a66f787-9e95-44f6-89b6-5cb7c318cbf0	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-06 13:51:47.771329	f4142808-5108-4e6a-915e-af0420786948	\N	\N	\N	\N
95f70341-5de5-4ddd-a7ba-0bc7111165c7	birth	2025-06-06	Town, FAR	OpenCRVS	{"trackingId": "BSKQOAU"}	2025-06-06 13:51:52.197362	95f59a4a-90b4-416d-b51c-5dd84a5850ec	\N	\N	\N	\N
2be67ab5-d07f-4707-b6b7-af57381bf3d2	birth	2025-05-10	Town, FAR	OpenCRVS	{"trackingId": "BY3JSJC"}	2025-05-29 13:15:22.26133	655366fc-d2e7-429c-a588-8fb9c19a6c9a	\N	REGISTERED	2025-06-06 14:53:38.684	Correction: Participant change
9469bd69-963d-46a3-a31b-daebcfa17f32	death	2025-06-05	FAR	OpenCRVS	{"trackingId": "DOCWVD7"}	2025-06-09 12:50:45.411914	2c968596-99d1-4961-a367-ed8e46c8cc9a	\N	REGISTERED	2025-06-09 12:21:08.402	\N
674fc8d3-03c7-43c9-84f8-a5365e0535e0	birth	2025-05-01	Health Institution, Fikombo HP	OpenCRVS	{"trackingId": "BAGM5A9"}	2025-06-09 15:11:18.934983	7e12d5ba-1f72-4d3e-8816-ebfb46783012	\N	\N	\N	\N
a9647a21-f0ce-44f6-a5c0-267070190e07	death	2025-06-03	FAR	OpenCRVS	{"trackingId": "DSSFAAK"}	2025-06-09 13:20:12.254246	b670ff83-56a7-4beb-bd21-252c374809a7	\N	DECLARED	2025-06-09 13:20:10.532	\N
768ffb56-d828-4792-a259-a2a4661f1c37	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:10:48.54548	adf5c701-2251-45b6-921e-80c8c51f289d	\N	\N	\N	\N
3712771a-b05b-4d64-b1e8-f3e5dd5e477b	birth	2025-06-04	Unknown, FAR	OpenCRVS	{"trackingId": "BAGPYE2"}	2025-06-05 21:37:34.981671	fd7905d5-231d-44a8-8c64-9d784e6a6b8f	\N	REGISTERED	2025-06-05 22:36:34.457	Correction: Participant change
5eeac30e-de18-4159-abae-9e5ccbcb06e5	birth	2025-05-10	Town, FAR	OpenCRVS	{"trackingId": "BMVXRTH"}	2025-06-09 15:10:51.88176	83092f2d-3029-4661-84ba-5052074d539e	\N	\N	\N	\N
7dbf23a2-b3ba-4ed9-9b58-507bffc4ae3c	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:10:58.833414	b13ac127-2d6f-4459-8288-499cbe000630	\N	\N	\N	\N
7ebdc0f2-5eee-4b27-93c5-5bcb8624d32e	birth	2025-05-01	Town, FAR	OpenCRVS	{"trackingId": "BSFPTIV"}	2025-06-09 15:11:02.655855	f2b7e341-ba20-4b23-aa0b-d1a88d1b833e	\N	\N	\N	\N
b18d3597-e7ce-43c0-9bbd-009e2f0fb7f5	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:11:08.920617	96a3d905-af3b-47b7-98dd-c745c5ec981c	\N	\N	\N	\N
edda463c-2545-4956-95a2-40d33b495e47	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:11:47.359156	db41cd6c-322f-4238-b133-c9eac541681e	\N	\N	\N	\N
65aae183-361a-4098-b4a5-c57ced73498a	birth	2025-05-01	Health Institution, Fikombo HP	OpenCRVS	{"trackingId": "BYVH4ZB"}	2025-06-09 15:11:51.254894	e696878d-cf0b-49c2-ae64-ed3b7630ba87	\N	\N	\N	\N
cf9dceb3-ea79-4c33-bc24-bb826c4df870	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:11:59.460267	f3e8b525-3411-42c5-bfd6-06c42d57ef4a	\N	\N	\N	\N
dad918dc-d06c-4d65-89a9-7c164d9da73c	birth	2025-05-01	Health Institution, Fulaza Rural Health Centre	OpenCRVS	{"trackingId": "BTTQNFQ"}	2025-06-09 15:12:03.332952	7ab54c9d-74f8-4c05-bf6b-a63ca945bb0f	\N	\N	\N	\N
15bbdf73-219d-4d55-82a5-bb40d72714eb	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 15:12:09.611721	ff87b6bc-9d2e-4ec6-a6d4-4b1a054515ac	\N	\N	\N	\N
b283061d-a38c-48f6-8183-278d2dea1a29	birth	2025-05-01	Town, FAR	OpenCRVS	{"trackingId": "BXGXIXD"}	2025-06-09 15:12:13.547113	6d57b21f-9b44-4e27-b845-2a7fa9740f05	\N	\N	\N	\N
f5b0dc94-8176-4165-85a8-792b2a1d2616	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 16:54:07.844878	95a62c8b-efc9-49b7-a8f8-0edb741b7992	\N	\N	\N	\N
ec4b44cf-e2b0-486b-a0e6-327288b03e09	birth	2025-01-01	Health Institution, Fikombo HP	OpenCRVS	{"trackingId": "B8BAMHS"}	2025-06-09 16:54:11.34673	73c7e199-7cab-451c-80d0-a9739e006216	\N	\N	\N	\N
f69b682a-46b9-4fce-992e-94a145f20c2c	birth	1981-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 17:05:10.13165	86665a2a-6d1b-4d1a-9c00-d15c39705fc7	\N	\N	\N	\N
d4c0ae9b-cf09-4fde-a665-2e34661958be	birth	2025-05-05	Town, FAR	OpenCRVS	{"trackingId": "B4RXRSR"}	2025-06-09 17:05:17.235223	000d5388-1f67-42e3-81ac-9461f8641918	\N	\N	\N	\N
bd300d78-5359-46f4-8fdd-0bcc3a33d23e	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 17:05:24.819056	18f50fc2-589c-4548-828c-7de46f45c471	\N	\N	\N	\N
afd344cb-6a0c-49c2-8d88-a7ee0e2e5c7f	birth	2025-06-05	Town, FAR	OpenCRVS	{"trackingId": "BENOJ08"}	2025-06-09 17:05:28.27219	c13e5c4b-58d3-4767-9407-63247dd7c1a3	\N	\N	\N	\N
f6ed2e77-ee37-468d-a4f4-883543ad83ff	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-09 17:05:36.165182	80dd227a-a5b9-41fb-81a7-b27abceb9c88	\N	\N	\N	\N
594fb5da-c983-437d-8c6b-5965837a7a58	birth	2025-06-06	Town, FAR	OpenCRVS	{"trackingId": "BHT4UAC"}	2025-06-09 17:05:40.746264	e4245ac9-f34a-4d45-8a6b-9d840a4b2ed6	\N	\N	\N	\N
f5f0890e-f9c4-4962-aa02-66a6d05c2ca4	birth	1998-03-12	London, UK	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:43.787379	d3b56991-b9ee-455f-a4dc-301ae3294c2a	\N	active	2025-06-10 09:43:27.095	\N
4d0d5bf5-30cc-430c-9a44-41bc06585054	birth	2001-07-25	New York, USA	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:45.406033	2b369846-2407-4b8e-bb37-7c6adf581100	\N	active	2025-06-10 09:43:27.095	\N
2d7414a9-ddad-4d89-9a1b-0f1a33f0c18d	birth	1995-11-03	Tokyo, Japan	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:47.1015	15daba7d-7723-4bbb-b618-b68608298ad1	\N	active	2025-06-10 09:43:27.095	\N
6a56c3eb-dd1e-4a70-b3e3-ab22b9db0aea	birth	2003-04-08	Paris, France	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:48.799605	fd635509-dbf3-41ea-90ad-ed24ecd3a5ee	\N	active	2025-06-10 09:43:27.095	\N
153869aa-c579-467e-834c-9a1b3ea74807	birth	1999-09-30	Sydney, Australia	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:50.405852	6d25d73d-72e1-4826-baf5-56b3ff548cc4	\N	active	2025-06-10 09:43:27.095	\N
47d9e7b2-300d-4cc2-8001-6b84bd68a488	birth	1983-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-10 09:43:52.303676	124613fc-49ce-4823-b2e2-38420a4d4f48	\N	active	2025-06-10 09:43:27.095	\N
c30a6635-39e1-4a42-a7b1-3a582564bdd5	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-10 10:01:34.920869	d76895b7-0004-4ebd-8b40-decc4590e14b	\N	active	2025-06-10 10:01:27.483	\N
f339c0bd-3364-4c50-9f04-6aabd0d0062d	birth	1969-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-10 10:01:38.322922	5d495b1b-6ebd-4040-93b1-1dfba997102a	\N	active	2025-06-10 10:01:27.483	\N
6ddf0b9e-9bf1-45ec-a7ba-6461df61e36e	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-10 11:22:03.984753	0a5ca94f-8134-4fb1-958d-25a3f29d6e9e	\N	\N	\N	\N
f9568977-54a6-4d95-a55e-5f7642a50c08	birth	2025-06-06	Town, FAR	OpenCRVS	{"trackingId": "BTABWXZ"}	2025-06-10 11:22:08.35089	a9de7368-b562-4e89-a6fe-2d4ba857d507	\N	\N	\N	\N
8db6e53a-da20-4cb3-b9ec-75ea77f5ed84	birth	1970-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-10 12:27:00.075099	411cc750-b3ee-403f-9955-64a6b1e1b4f7	\N	\N	\N	\N
011d59a1-391f-4f4c-81e7-eb774808f280	birth	2025-06-07	Health Institution, Ibombo Rural Health Centre	OpenCRVS	{"trackingId": "BCKPAT0"}	2025-06-10 12:27:04.969667	30e50e57-6ac9-4d46-ac6e-5d56b9b9f0ca	\N	\N	2025-06-10 13:17:44.356	Correction: Participant change
c1cc18db-5708-4799-95c5-963a9f1b1051	death	2025-06-09	FAR	OpenCRVS	{"trackingId": "DWOUTYA"}	2025-06-10 13:45:22.980985	cb5df1d8-ff09-471a-b519-adf5a64778da	\N	REGISTERED	2025-06-10 13:45:19.429	\N
18e4f975-6f93-43c0-af2f-5166f4785a4a	birth	1949-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-10 14:33:26.435564	4858f25c-b2a7-4879-a107-273939a9ef29	\N	\N	\N	\N
d245ee11-95d3-4aef-ad34-1b3145811385	birth	2025-06-01	Town, FAR	OpenCRVS	{"trackingId": "BYW6OWN"}	2025-06-10 14:33:30.372621	f469956a-80e2-4d0e-bf94-80f678af86f3	\N	\N	2025-06-10 14:35:05.659	Correction: Participant change
eb404571-8145-4ddb-afce-14c2f1bb5947	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-10 16:00:02.189814	330d8771-8aa7-4834-898f-697743bae388	\N	\N	\N	\N
4ea9117c-ff80-4975-a4f4-9452282d5af3	birth	2025-06-01	Town, FAR	OpenCRVS	{"trackingId": "BO4W98H"}	2025-06-10 16:00:06.966231	dd330d4f-2618-4a67-a338-d97524b3acf8	\N	\N	2025-06-10 16:01:46.708	Correction: Participant change
a06bcb9f-aafb-428d-afd5-8724895abcbc	death	2025-06-01	FAR	OpenCRVS	{"trackingId": "DCIWZXR"}	2025-06-10 16:04:26.294847	5d0d510e-32fc-410c-bd50-c7b637e097c8	\N	REGISTERED	2025-06-10 16:04:23.313	\N
96c851d6-98af-465b-9b29-2b106a58aca8	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-11 08:58:10.437476	e107605a-0c89-417a-8979-5bf6db63e100	\N	\N	\N	\N
ab11b4b7-f7b6-407c-a737-c68cbad2b02b	birth	2025-06-01	Health Institution, Ibombo Rural Health Centre	OpenCRVS	{"trackingId": "BZUPA93"}	2025-06-11 08:58:13.72291	10087ec8-7f20-4572-8f36-54719e8c2724	\N	\N	2025-06-11 09:00:22.179	Correction: Participant change
705e7d0f-c4ef-4321-a487-5348891cdd33	death	2025-06-05	FAR	OpenCRVS	{"trackingId": "D05PMMQ"}	2025-06-11 09:05:15.892731	35e9e3f6-97c2-46f4-b3b7-4cdc42a37400	\N	REGISTERED	2025-06-11 09:05:12.965	\N
eab4aae4-7f3a-45bd-aaca-74b3f28f8830	birth	1969-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-11 13:25:43.742811	8a429d1f-79c7-4eed-a423-40eeaad40a09	\N	active	2025-06-11 13:25:40.15	\N
61470756-3d5f-4f87-8f3a-1be21e128712	birth	1970-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-11 15:08:11.84545	40349675-c43a-4e86-870f-35635500f1ce	\N	\N	\N	\N
8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	birth	2025-06-10	Town, FAR	OpenCRVS	{"trackingId": "BAF1XQJ"}	2025-06-11 15:08:15.257094	a3b29c56-01bf-4ac0-aa75-9fe44c815fea	\N	\N	2025-06-11 15:12:16.219	Correction: Participant change
1ecee6bb-060f-4c2d-905f-4e447efcea69	death	2025-06-08	FAR	OpenCRVS	{"trackingId": "DIYDF0O"}	2025-06-11 15:18:21.885327	ffd479fd-a536-4c42-9456-b530d933d2f3	\N	REGISTERED	2025-06-11 15:18:18.993	\N
433c0c62-5054-4740-b106-4180628819af	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-12 08:12:46.843227	7ba6e37e-a7e4-4670-bd6a-bf4db7a6a43f	\N	active	2025-06-12 08:12:44.13	\N
c6c14eca-091c-48db-a5ac-9839e0277b26	birth	1990-01-01	Unknown	DerivedFromMarriage	{"generatedFrom": "marriage registration"}	2025-06-12 08:52:40.786733	2cf61c07-049f-45b9-97a6-06f911852e29	\N	active	2025-06-12 08:52:36.647	\N
a3b38c9e-3a38-4bdc-821e-c6fc7ea21bc6	birth	1992-02-02	Unknown	DerivedFromMarriage	{"generatedFrom": "marriage registration"}	2025-06-12 08:52:42.060964	fa6f03e3-5242-4718-97ef-df09746a7e9d	\N	active	2025-06-12 08:52:36.647	\N
313a7e96-e961-489a-b0e5-6bc0f869de17	marriage	2025-06-12	Ibombo District Office	OpenCRVS	{"trackingId": "MZOVGOT", "registrationNumber": "2025MZOVGOT"}	2025-06-12 08:52:46.148389	e0b489e3-0658-43d7-98f1-81324c87d5d6	\N	active	2025-06-12 08:52:36.647	\N
d7ffabde-791e-4881-99ff-dd2129242d80	birth	1970-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-17 15:09:46.918086	e3e18916-8950-4af9-96d8-26eb514966e0	\N	\N	\N	\N
cb456ae0-2ef7-486d-b287-f34b37a0e8b4	birth	2025-06-06	Unknown, FAR	OpenCRVS	{"trackingId": "BWWQGSZ"}	2025-06-12 09:06:54.317377	9fa24ae6-e12e-4b23-a335-50a9d95488de	\N	REGISTERED	2025-06-16 12:40:18.872	Correction: Participant change
c366b982-5f20-4b11-8288-ad2b317e6148	death	2025-06-08	FAR	OpenCRVS	{"trackingId": "DNXD5P3"}	2025-06-16 12:44:09.226897	8b0377eb-57fb-4a02-8725-8d21882bdc38	\N	REGISTERED	2025-06-16 12:44:07.832	\N
959058b4-19bf-4481-99a2-5d1ab4e66fd6	birth	2025-06-01	Town, FAR	OpenCRVS	{"trackingId": "BKIVTZR"}	2025-06-17 15:09:50.450218	88865c77-6306-4131-b3c7-cc187316cab0	\N	\N	2025-06-23 14:43:38.525	Correction: Participant change
b9743da3-3d58-4270-9a20-c7669694edaf	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-23 15:32:50.677015	5462658a-f6f1-412b-9141-23d7d91496a7	\N	\N	\N	\N
1a092099-a402-4dcb-bb17-d6ff3afb14f0	birth	2025-06-01	Town, FAR	OpenCRVS	{"trackingId": "B2WWCMY"}	2025-06-23 15:32:54.220955	3b518c5a-5c67-41f5-9605-7cd765206cfc	\N	\N	2025-06-23 16:30:52.097	Correction: Participant change
6b75dfb6-c6dc-4af4-beaa-c56e2dd68109	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-25 14:52:03.712626	38cc50bb-9a69-4eb1-bb61-602f6dde5264	\N	active	2025-06-25 14:51:59.324	\N
45f79320-5773-4014-9bb0-d98aaf83e36a	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-25 15:01:24.871577	a2dccb06-cfb9-496a-8416-52286d0360a6	\N	\N	\N	\N
9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	birth	2025-06-01	Health Institution, Bombwe Health Post	OpenCRVS	{"trackingId": "BNYNFIS"}	2025-06-25 15:01:28.811182	a9f7cba5-e021-4a16-82f9-5ad9a16124d7	\N	\N	2025-06-25 16:10:57.244	Correction: Participant change
1e3f0009-00bd-4f7f-88cf-0fc8aacd3d9e	death	2025-06-02	FAR	OpenCRVS	{"trackingId": "DHE9BHJ"}	2025-06-25 15:17:48.338747	06ea6ecb-828b-4fb2-afbd-62f2f246773a	\N	REGISTERED	2025-06-25 15:17:45.284	\N
35112ad7-3b3a-4119-b14c-c98a47835178	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-25 15:40:30.116778	a76de5bc-2e0a-4ccd-be5c-f2f27b98d557	\N	active	2025-06-25 15:40:26.996	\N
1bd49fe1-bc35-4da1-b526-9fa74f8cc849	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-27 11:15:58.299873	7a4f5cc2-88b2-4229-83dd-077805d79c55	\N	active	2025-06-27 11:15:55.049	\N
09cfe392-6f7b-4524-bd16-3a1946bc0b84	birth	1968-01-01	Town, FAR	TestGenerator	{"note": "Generated test record"}	2025-06-27 11:16:04.907209	99588a4d-2d21-4916-b7db-8299faaecf40	\N	active	2025-06-27 11:16:01.379	\N
f86a2d0c-9a6e-490d-be51-52f2d48088c0	birth	1975-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-27 11:55:53.976528	f4db1631-ef6b-4c2c-9609-e0e77c134599	\N	\N	\N	\N
d8eccbcf-77c3-49e0-80b2-6a735f22ee20	birth	2025-05-16	Town, FAR	OpenCRVS	{"trackingId": "BDBQNUO"}	2025-06-27 11:55:57.741059	80180d42-5111-4f2a-ba8d-0a9ce1de6d2a	\N	\N	2025-06-27 12:45:17.159	Correction: Participant change
53bd09af-87f4-47b4-9964-a9b810730ecb	birth	1970-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-27 13:34:47.188518	023693f6-cc4f-40d0-9e32-deddc89f094a	\N	\N	\N	\N
d9c83380-f704-480b-8329-0cae8decc028	birth	2025-06-15	Town, FAR	OpenCRVS	{"trackingId": "BITDOD4"}	2025-06-27 13:34:50.642367	27fe43ca-1727-49ad-81a6-4382c0e7a660	\N	\N	2025-06-27 13:43:16.782	Correction: Participant change
c2dcdb8b-da09-43f2-978e-4b570b1ba628	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-06-27 19:43:56.413406	15728f10-a07d-4222-89af-790fbc932353	\N	\N	\N	\N
0c65367a-189f-4411-bc9f-88cd08b9032d	birth	2025-01-01	Town, FAR	OpenCRVS	{"trackingId": "BUIWAKY"}	2025-06-27 19:44:00.245036	a2517d23-7f8a-412c-8dcd-e3de87633d91	\N	\N	\N	\N
0ecb9281-2205-43d8-8620-cf37235befae	birth	1985-01-01	Unknown	seed	{"note": "generated birth by crvs"}	2025-07-18 14:47:16.919656	5d2d0ca5-3434-440f-8759-1e6fb9116e97	\N	\N	\N	\N
7e764297-4fa1-4ff3-a687-e9b652cec5c0	birth	2025-07-01	Town, FAR	OpenCRVS	{"trackingId": "BRBDMBA"}	2025-07-18 14:47:18.148185	cd4ad533-f0a9-48eb-b775-841b9e301905	\N	\N	2025-07-18 14:54:51.082	Correction: Participant change
\.


--
-- Data for Name: event_participant; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.event_participant (id, person_id, event_id, role, relationship_details, created_at, crvs_person_id, status, ended_at, remarks) FROM stdin;
f78b3386-3839-4bdd-8c81-0865d479669c	dd08bb18-5f3f-4479-ab18-853608ab2742	3e5782a1-edf9-454c-bb7c-4e2a2a38b5f8	subject	{"seed": true}	2025-05-13 15:29:48.881053	\N	active	\N	\N
5cb6ea54-969b-4c1d-9dff-7d07cc728249	9da4f95a-3bdb-42c5-a55b-916779251185	b9ea837f-bee8-427c-ba76-d85547ee1121	subject	{"seed": true}	2025-05-13 15:29:48.887691	\N	active	\N	\N
716cb4ae-8f61-482f-b27d-4285d62244b7	25f2cdab-c4fc-4693-a39d-356d4d7c79fa	0af4e53c-16d0-43db-9c06-a90243ed44f6	subject	{"seed": true}	2025-05-13 15:29:48.893946	\N	active	\N	\N
7debd9c1-f4cd-420c-9c32-70ab5dbb6df8	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	446b89ad-e88f-43af-88a5-4b880df3f0ac	subject	{"seed": true}	2025-05-13 15:29:48.902814	\N	active	\N	\N
3bf5adfb-eb97-44f8-aec5-3b63b2e03295	7a6633f5-3186-4222-b7a2-32c9738637e5	d96a7fee-922f-402d-b209-04f87e9afa20	subject	{"seed": true}	2025-05-13 15:29:48.908844	\N	active	\N	\N
c45dba14-7e9d-4d2d-a111-11f7daf5446b	854e958a-b6b7-44d1-8795-da54dab59c84	cf4562d4-8117-485b-9db3-1bf5778386c1	subject	{"seed": true}	2025-05-13 15:29:48.915529	\N	active	\N	\N
45a330e7-eec6-43be-a005-426f750104f9	3df5bc57-427c-446c-8201-f9695bcdd6d5	9a232eb2-cf8f-45c8-92f3-d5d09745b92c	subject	{"seed": true}	2025-05-13 15:29:48.920086	\N	active	\N	\N
36dfe76c-f386-4992-94ec-fd0b6e70cde8	e1148e47-a783-4516-b041-abd642405c7c	3ab85b56-3084-48e9-ad1b-37ffbad0e9c8	subject	{"seed": true}	2025-05-13 15:29:48.926382	\N	active	\N	\N
ffbe0c54-e41e-4463-9450-87e20dbb295c	8e7ec9cf-a941-46a6-9e0b-1aaee0d74e10	e0efdc26-2ab8-489f-8b22-04286f677fd8	subject	{"seed": true}	2025-05-13 15:29:48.941991	\N	active	\N	\N
a574f56b-9577-4542-951d-a4cdcbeda992	bb44ff20-8ed4-42c1-9901-4322e4b4c561	c7f0fef5-e3f1-42f2-8ecc-1c0ecac47f18	subject	{"seed": true}	2025-05-13 15:29:48.965333	\N	active	\N	\N
af440467-bb93-4777-87a9-6f0e8e531a99	0bba79ee-cc6a-4953-aa72-897a18dc0967	582f0314-5cfe-49c6-bc93-341b169eaa0d	subject	{"seed": true}	2025-05-13 15:29:48.973114	\N	active	\N	\N
84387fe7-da77-404f-9103-d4020b802ec1	8824f3ca-aaf9-43de-9960-6e0c32db6181	cf1ce9a3-95d2-4056-8422-ffe57d2a9a2d	subject	{"seed": true}	2025-05-13 15:29:48.977682	\N	active	\N	\N
6cf02ce4-6962-4c7e-8c29-8f6473b3577f	bffaaa11-4ddb-4928-9edf-8b8618087db7	5f99a846-fbb5-44d1-9e91-6fdeec7fe82d	subject	{"seed": true}	2025-05-13 15:29:48.984584	\N	active	\N	\N
1960833e-6e93-441b-abfc-d93b9aa6bbaa	4957eabe-96c3-490f-8985-f8eda8833b9b	1c8a7f44-5cc2-4d62-a80c-2a648fb42a81	subject	{"seed": true}	2025-05-13 15:29:48.988793	\N	active	\N	\N
237af15b-8d4d-4c4f-8492-699de59f11cd	40dbe816-0c48-418a-a2fa-eff40a829fe1	38993fa5-93fc-4705-8676-29f8ddddfcaa	subject	{"seed": true}	2025-05-13 15:29:48.992381	\N	active	\N	\N
c89f3502-823a-4f10-bbfb-091be6034584	3d6540c3-aa32-4f9c-9fe0-d62aba496731	072eacc6-f8c9-47b6-9046-195901ef1889	subject	{"seed": true}	2025-05-13 15:29:48.9975	\N	active	\N	\N
d5807192-9f65-47f1-adec-e8c0e50da1fd	fa34a844-b81a-4ed0-aa9e-3e311cfd3ad8	48850dee-d917-4437-8969-2932d9b7dc64	subject	{"seed": true}	2025-05-13 15:29:49.003144	\N	active	\N	\N
1b18a751-709f-4c65-8191-3a200af776a3	3c6a948d-cc5c-4efc-9e2a-525c49b5321c	70e25861-002d-484e-9c20-81bb102c1991	subject	{"seed": true}	2025-05-13 15:29:49.006993	\N	active	\N	\N
1ffc59fd-9be6-45b9-851a-da16ff6b4098	b7987a2f-e8ec-43ac-bdbc-2ce706f15138	1de479b6-a655-402b-bfee-019e740421d3	subject	{"seed": true}	2025-05-13 15:29:49.012274	\N	active	\N	\N
c3225142-ef00-444d-a186-fdc20e77409d	35bf5c76-2752-4a55-9818-c0523877f0bd	72052043-1c32-4b4d-a27b-e38f77982e83	subject	{"seed": true}	2025-05-13 15:29:49.018739	\N	active	\N	\N
99725201-1c38-4649-a7fd-7aeecb593173	fbdf37fc-6e9a-4c4d-b5e8-3a7c3a1535b8	0f2c944e-e19b-42b9-8b1b-6bdf7585efe9	subject	{"type": "child"}	2025-05-29 13:12:46.911284	1347ef35-b6b4-41b6-80ba-e4ad936563ab	active	\N	\N
9de553fe-8db6-4d1b-a19d-1543c1796b75	3df5bc57-427c-446c-8201-f9695bcdd6d5	0f2c944e-e19b-42b9-8b1b-6bdf7585efe9	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-05-29 13:12:48.355184	2028c326-aa39-4b5b-9d3a-9408df1e02cf	active	\N	\N
4b8d849b-8afb-4228-8a43-249434158c42	46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	2be67ab5-d07f-4707-b6b7-af57381bf3d2	subject	{"type": "child"}	2025-05-29 13:15:23.873548	39dc1319-1b5d-449d-a395-13259ca0151e	active	\N	\N
5ad14fd1-8abe-4697-977e-fae7874357d3	3df5bc57-427c-446c-8201-f9695bcdd6d5	2be67ab5-d07f-4707-b6b7-af57381bf3d2	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-05-29 13:15:25.454695	f6a2de58-b176-49f7-b2cc-0465898a7b7b	active	\N	\N
7db6083c-8fbc-402b-9b5e-f9d95610891d	92994d6d-8729-4ccf-9f05-a97bd09f1d71	49acae79-040b-4ef4-95bb-ec67808f6ffe	subject	{"type": "child"}	2025-06-02 11:08:35.697926	cbb8d306-731e-4197-a380-cc280068ed72	active	\N	\N
c1d98e2d-b712-4ebc-9483-fe85e24e353b	3df5bc57-427c-446c-8201-f9695bcdd6d5	49acae79-040b-4ef4-95bb-ec67808f6ffe	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-02 11:08:36.737482	d2020886-8d3d-4572-83eb-5f6678c5fcad	active	\N	\N
94f2bb9a-3520-48c8-a823-7790a03a5fdb	47fb0570-8de5-4b18-b727-d10200eb5b86	2d5e4536-80e1-4840-b456-5039c9e97882	subject	{"type": "child"}	2025-06-02 11:22:28.934023	618f0518-e28a-4a05-a723-edb3e88e3e87	active	\N	\N
c856201b-3ac8-4769-923f-fcd2b99ed73e	3df5bc57-427c-446c-8201-f9695bcdd6d5	2d5e4536-80e1-4840-b456-5039c9e97882	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-02 11:22:30.037094	73167549-cc6e-4d89-943c-4a3a0005f078	active	\N	\N
d72bdb63-310e-4e49-ba7b-35ca1b7ff7d0	75d704fc-cd76-4dc0-afae-4bad63860665	47ff409a-a403-4a5e-821f-9a7bab4fbe56	subject	{"type": "child"}	2025-06-02 11:50:10.659861	bb2c0cd3-7544-486a-b291-b76a83e17e32	active	\N	\N
75b4b572-2975-40cd-bd29-f559d896ad35	3df5bc57-427c-446c-8201-f9695bcdd6d5	47ff409a-a403-4a5e-821f-9a7bab4fbe56	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-02 11:50:11.208222	1972d580-6ed5-486e-8d82-6f2be15dbacb	active	\N	\N
2af12d73-78bb-4a22-b117-e3119a82619a	9dd7119a-7619-4ec5-b2aa-c5acf44cfc54	42ac5713-2ebc-469c-92d1-15bc43da7e86	subject	{"type": "child"}	2025-06-02 19:35:43.466731	bdb15741-bb7c-4b76-9c4c-62aa0de6d907	active	\N	\N
29e0f71e-d40e-4c93-975b-436a24796470	25f2cdab-c4fc-4693-a39d-356d4d7c79fa	42ac5713-2ebc-469c-92d1-15bc43da7e86	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-02 19:35:43.97746	dd9e84c2-6a8e-42ad-bef9-d15e7e8faa3a	active	\N	\N
613663ed-c1f4-4ccd-87b0-0a5982ecfe2b	a39d188d-6df9-4d7f-b3e3-16fd26bc58dc	1e83741c-84bb-4d7d-a00a-5581a5d8490e	subject	{"type": "child"}	2025-06-04 10:59:58.945649	8b9e3880-7fc5-4cda-bbf2-0a478cec6c2a	active	\N	\N
5db8da71-5588-4147-bb05-746d71037bfa	d3802f0d-a682-4a0e-98d9-1a8454e91590	1e83741c-84bb-4d7d-a00a-5581a5d8490e	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-04 11:00:00.598763	d16e43d1-8727-43d5-8086-932463bb79d7	active	\N	\N
53f75665-6a18-4a7d-9e05-e09a8ee7f484	0a9c7ec5-8a53-4562-b542-ac373339212a	e8d2e3c8-a603-4471-aea9-4dfa7fb65bce	subject	{"type": "child"}	2025-06-04 12:01:47.383523	3d3b030a-665a-49b0-aaab-a3195473bca1	active	\N	\N
489ab635-75fd-46f1-ae62-c12a34b40c09	679644ac-a9e5-4fdf-a974-d4d76869d193	e8d2e3c8-a603-4471-aea9-4dfa7fb65bce	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-04 12:01:47.865094	d41110c0-bbb5-4ec7-81e8-94e99edfef13	active	\N	\N
0181eb8d-1b83-4e57-a6d8-bd7895f5a6b4	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	2be67ab5-d07f-4707-b6b7-af57381bf3d2	father	{"type": "father", "relationship": "FATHER"}	2025-06-05 14:47:40.826	7f0b7f3c-e8d3-4f39-9fda-71b1a65eda5a	inactive	2025-06-05 15:39:42.699	Father details removed per court order 2
853236eb-b110-4171-a743-c1fde48e803a	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	2be67ab5-d07f-4707-b6b7-af57381bf3d2	father	{"type": "father", "relationship": "FATHER"}	2025-06-05 15:58:43.199	7f0b7f3c-e8d3-4f39-9fda-71b1a65eda5a	inactive	2025-06-05 16:04:19.641	Court Order
892920ba-6856-420d-8ac0-3ae6f4287c23	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	2be67ab5-d07f-4707-b6b7-af57381bf3d2	father	{"type": "father", "relationship": "FATHER"}	2025-06-05 20:53:57.041	7f0b7f3c-e8d3-4f39-9fda-71b1a65eda5a	inactive	2025-06-05 21:34:20.837	Court Order 2
948b3fdb-9f5a-4801-8d5f-1c15e1d2e8f9	e2f1a133-4742-4f57-8e35-905bdf7cb5ac	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	subject	{"type": "child"}	2025-06-05 21:37:36.277773	98ab16ac-4272-40ec-ab45-c4737d8ff6b4	active	\N	\N
35515103-f33a-485c-8e96-227da34f5d2b	679644ac-a9e5-4fdf-a974-d4d76869d193	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-05 21:37:37.515645	762f3adc-c8e2-4509-8eeb-242b28579a16	active	\N	\N
1cf47702-086f-4359-8ce6-6308f6b6c1b1	dd08bb18-5f3f-4479-ab18-853608ab2742	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	father	{"type": "father", "relationship": "FATHER"}	2025-06-05 22:17:29.432	82fcf06c-9570-476b-bdbb-ef51fa39111e	active	\N	\N
885d94ae-8ca8-450c-85f4-8fbaf891defa	2399c5a9-b4a9-4e36-8532-acd6dce7ab10	8fb08553-093c-4009-bb7d-5264faa11e25	subject	{"import": "crvs"}	2025-06-06 13:51:37.903522	9c4ce4a2-d4b3-45ac-9274-a18ce5a672de	active	\N	\N
4a2073e0-11df-41ae-9bd3-cee9a74adb25	bb89dbd3-52d5-4c7d-bd99-300b9c427f9c	f518405d-b545-4a4a-a379-586da42470c3	subject	{"type": "child"}	2025-06-06 13:51:42.187163	40d3afad-31bf-4776-92fa-ca1a22707dff	active	\N	\N
86a22ebf-9306-42bf-9653-8f594a84bf1b	2399c5a9-b4a9-4e36-8532-acd6dce7ab10	f518405d-b545-4a4a-a379-586da42470c3	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-06 13:51:43.658183	9c4ce4a2-d4b3-45ac-9274-a18ce5a672de	active	\N	\N
970acfa3-2ae2-4a43-aeed-f6999b503fa9	f8d6bf11-3f1f-422a-8b5b-84f5c175fead	4a66f787-9e95-44f6-89b6-5cb7c318cbf0	subject	{"import": "crvs"}	2025-06-06 13:51:49.158016	bdf727d8-4bf3-458c-8538-0a8e73e25a93	active	\N	\N
1efeb617-cd5e-4557-88c5-799421b2126e	5ef5380e-2a5b-47df-a94a-d78722ba445f	95f70341-5de5-4ddd-a7ba-0bc7111165c7	subject	{"type": "child"}	2025-06-06 13:51:53.597299	0f607877-405d-4673-80b8-4c11226343e2	active	\N	\N
49e4c869-40ca-435e-ae05-ae632a5e1fd4	f8d6bf11-3f1f-422a-8b5b-84f5c175fead	95f70341-5de5-4ddd-a7ba-0bc7111165c7	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-06 13:51:54.952685	bdf727d8-4bf3-458c-8538-0a8e73e25a93	active	\N	\N
2b8a587b-7a10-474a-ad59-ec678a3b418a	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	2be67ab5-d07f-4707-b6b7-af57381bf3d2	father	{"type": "father", "relationship": "FATHER"}	2025-06-06 14:53:38.684	7f0b7f3c-e8d3-4f39-9fda-71b1a65eda5a	active	\N	\N
da83a2e9-7b00-4933-ba72-ae0718f0cbf6	dd08bb18-5f3f-4479-ab18-853608ab2742	9469bd69-963d-46a3-a31b-daebcfa17f32	subject	{"type": "deceased"}	2025-06-09 12:50:46.249144	c9a7e2e1-2bf8-4899-a9a5-5423a9c65b6e	active	\N	\N
600daf56-3ef5-43d4-915c-0dfdd4e1da1d	7a6633f5-3186-4222-b7a2-32c9738637e5	a9647a21-f0ce-44f6-a5c0-267070190e07	subject	{"type": "deceased"}	2025-06-09 13:20:13.073184	0455e8f0-88a7-4ce6-addf-bd65f54c7a01	active	\N	\N
1e7e30fb-7b19-458e-a4c7-ddf64bfeba2a	ff0ad433-88ff-4cc3-b0fe-a252290e39a2	768ffb56-d828-4792-a259-a2a4661f1c37	subject	{"import": "crvs"}	2025-06-09 15:10:49.220726	e80a3f4c-338a-48d6-a4de-dc3e8990c137	active	\N	\N
2d4421ce-4367-4994-9cec-3801db5ed3e0	69ec3c8f-aef7-4fda-9f34-22bce75e8d44	5eeac30e-de18-4159-abae-9e5ccbcb06e5	subject	{"type": "child"}	2025-06-09 15:10:53.15047	5f0cdcd0-106d-43c7-ae1f-87a4a32930bf	active	\N	\N
832b909c-eefd-4797-898c-0c2bfb2dead1	ff0ad433-88ff-4cc3-b0fe-a252290e39a2	5eeac30e-de18-4159-abae-9e5ccbcb06e5	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:10:54.393371	e80a3f4c-338a-48d6-a4de-dc3e8990c137	active	\N	\N
7aaa0671-e905-4cec-b1f5-1c8cdcd34c1a	28373367-53ba-4d6c-9881-c81b32ae4fff	7dbf23a2-b3ba-4ed9-9b58-507bffc4ae3c	subject	{"import": "crvs"}	2025-06-09 15:11:00.090006	700e681a-0a88-46c3-8dd5-a9ab71ab5adb	active	\N	\N
7b9282fe-6741-47e7-84ed-0aa9a6d06ab4	fe2dfcd7-6675-4baf-8506-0f65c3792e19	7ebdc0f2-5eee-4b27-93c5-5bcb8624d32e	subject	{"type": "child"}	2025-06-09 15:11:03.910547	4bdf55bc-a555-4de1-ab84-22820373e290	active	\N	\N
3b30c7ac-5267-4389-a47d-60ebf02f4c8d	28373367-53ba-4d6c-9881-c81b32ae4fff	7ebdc0f2-5eee-4b27-93c5-5bcb8624d32e	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:11:05.124013	700e681a-0a88-46c3-8dd5-a9ab71ab5adb	active	\N	\N
911b5733-89f7-4e62-bd2c-380d44b3f95f	c73dcb68-79bd-46ab-aef3-ba1a9b8b81b8	b18d3597-e7ce-43c0-9bbd-009e2f0fb7f5	subject	{"import": "crvs"}	2025-06-09 15:11:15.688357	7002ee2e-5416-4564-9f75-fde3f9a42018	active	\N	\N
64d128c3-bbec-40c3-9bde-c0b88fcfdeed	bf2a4ffc-e024-485c-833f-01f56912b3ac	674fc8d3-03c7-43c9-84f8-a5365e0535e0	subject	{"type": "child"}	2025-06-09 15:11:20.438738	c16b34df-92bc-433c-a67e-a4d9474bb2ef	active	\N	\N
df7ed23c-47d7-44c2-96bb-2b047afc8794	c73dcb68-79bd-46ab-aef3-ba1a9b8b81b8	674fc8d3-03c7-43c9-84f8-a5365e0535e0	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:11:21.840238	7002ee2e-5416-4564-9f75-fde3f9a42018	active	\N	\N
dc73aea9-ef75-4fa6-8c97-8b39e5329c55	96f5df53-a65f-4a84-ae93-ca6ab71f022e	edda463c-2545-4956-95a2-40d33b495e47	subject	{"import": "crvs"}	2025-06-09 15:11:48.018156	2706c226-65c4-41ed-92e3-16fa1d63dc0a	active	\N	\N
37426543-5355-44c9-8e72-e46bdebcad12	876df5f7-9559-4642-bef2-2664762ab9e9	65aae183-361a-4098-b4a5-c57ced73498a	subject	{"type": "child"}	2025-06-09 15:11:52.758309	0983eddb-3d7c-4ebc-931d-dcef267b69ff	active	\N	\N
e515d327-fe5c-4020-b666-4cd75c7a5329	96f5df53-a65f-4a84-ae93-ca6ab71f022e	65aae183-361a-4098-b4a5-c57ced73498a	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:11:54.354969	2706c226-65c4-41ed-92e3-16fa1d63dc0a	active	\N	\N
fb12320e-f508-4209-8a6c-7a39619b4f8e	09361c85-ae70-4647-bcb3-269e394cfaf5	cf9dceb3-ea79-4c33-bc24-bb826c4df870	subject	{"import": "crvs"}	2025-06-09 15:12:00.857091	f57172bc-6449-465d-bbff-25ada3177546	active	\N	\N
0f4628b4-b5e9-4d53-ba0e-180c959faa1e	08b6e869-9e57-41c5-adac-d9645cffc678	dad918dc-d06c-4d65-89a9-7c164d9da73c	subject	{"type": "child"}	2025-06-09 15:12:04.625194	710f2957-920a-4272-8c8b-86d6b5a3f49d	active	\N	\N
a8ea8fa2-57b5-4f21-939a-eb1707b0fa94	09361c85-ae70-4647-bcb3-269e394cfaf5	dad918dc-d06c-4d65-89a9-7c164d9da73c	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:12:05.910177	f57172bc-6449-465d-bbff-25ada3177546	active	\N	\N
9d6cb2df-58e9-4544-b6f6-1310b4bb3ac4	8841bb97-3b84-443f-b9d5-1c979d5d1703	15bbdf73-219d-4d55-82a5-bb40d72714eb	subject	{"import": "crvs"}	2025-06-09 15:12:10.94457	ccdfb332-8cde-41d5-ba6a-c9990cb99b8d	active	\N	\N
44c5435e-4a9e-4815-b698-263003e46604	4b29a876-51ff-4f4f-b8e0-6a07132f3d7f	b283061d-a38c-48f6-8183-278d2dea1a29	subject	{"type": "child"}	2025-06-09 15:12:14.845566	dfc97244-fb52-40b6-bb71-cb1c2e7501be	active	\N	\N
69319a66-47a9-478d-a87a-322305200f02	8841bb97-3b84-443f-b9d5-1c979d5d1703	b283061d-a38c-48f6-8183-278d2dea1a29	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 15:12:16.239157	ccdfb332-8cde-41d5-ba6a-c9990cb99b8d	active	\N	\N
838c2695-4cab-4992-a72e-94fc1698f437	5abf3659-3d05-42a1-9aa7-cab6bec3751b	f5b0dc94-8176-4165-85a8-792b2a1d2616	subject	{"import": "crvs"}	2025-06-09 16:54:09.249937	46281ccc-4919-4063-b282-c6daa9ec1ce2	active	\N	\N
ac47cd0c-bafa-4050-a643-65b47692d3e8	bc8e154e-e534-4b4f-b60a-56615bdff356	ec4b44cf-e2b0-486b-a0e6-327288b03e09	subject	{"type": "child"}	2025-06-09 16:54:12.844163	f2bc13c2-022b-4f1a-81ab-1aa09e63dd64	active	\N	\N
40bcb9cf-66e7-4ea8-87b1-edc3171c9d39	5abf3659-3d05-42a1-9aa7-cab6bec3751b	ec4b44cf-e2b0-486b-a0e6-327288b03e09	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 16:54:14.450797	46281ccc-4919-4063-b282-c6daa9ec1ce2	active	\N	\N
fb8d22e8-6bdf-4037-aa05-0bfed4a9c67b	060d2b75-b3ab-4e57-83ef-7a7d81f04981	f69b682a-46b9-4fce-992e-94a145f20c2c	subject	{"import": "crvs"}	2025-06-09 17:05:11.928846	649afb85-4e3b-48c4-95c4-27916a175ad7	active	\N	\N
0d386553-35ff-419a-bab3-a27e822d154f	822298df-310a-423c-9868-baef9f74f614	d4c0ae9b-cf09-4fde-a665-2e34661958be	subject	{"type": "child"}	2025-06-09 17:05:19.028375	dfd4ef95-0f52-401c-856b-0839b0665f8b	active	\N	\N
45f35de8-c00d-46da-a687-a3ea4fd41004	060d2b75-b3ab-4e57-83ef-7a7d81f04981	d4c0ae9b-cf09-4fde-a665-2e34661958be	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 17:05:20.624299	649afb85-4e3b-48c4-95c4-27916a175ad7	active	\N	\N
4df03e1e-c387-4e4e-a827-0f45324a1580	9bea87b9-e213-4dbb-9a66-209353cf3422	bd300d78-5359-46f4-8fdd-0bcc3a33d23e	subject	{"import": "crvs"}	2025-06-09 17:05:26.206316	1418d6cf-aacb-45cb-8b47-bd86e6c2aaa0	active	\N	\N
b67a6437-6ab2-4b87-88a3-43c35fac5698	7349640a-f9c3-4225-9a88-e8b4cbdd67d7	afd344cb-6a0c-49c2-8d88-a7ee0e2e5c7f	subject	{"type": "child"}	2025-06-09 17:05:29.967699	cb5ec1a4-91df-43a0-af29-95fd3b248d04	active	\N	\N
a3b1821e-c2b1-4774-bb54-f2a037affb80	9bea87b9-e213-4dbb-9a66-209353cf3422	afd344cb-6a0c-49c2-8d88-a7ee0e2e5c7f	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 17:05:31.475756	1418d6cf-aacb-45cb-8b47-bd86e6c2aaa0	active	\N	\N
a999395d-ef2a-4ed2-a515-5b63a1319ea5	7bd4503e-f9e5-48b0-8d2d-8704229973a7	f6ed2e77-ee37-468d-a4f4-883543ad83ff	subject	{"import": "crvs"}	2025-06-09 17:05:37.686977	c69c98b6-43d1-481d-8f30-54ff9711c7d8	active	\N	\N
76352902-201e-40dd-b5d2-88e746031287	ff233649-012f-41ac-8a97-96922dae0d22	594fb5da-c983-437d-8c6b-5965837a7a58	subject	{"type": "child"}	2025-06-09 17:05:42.1181	1c9f8ba0-b28f-46bb-ba6b-0eae877187dd	active	\N	\N
14713f63-372d-494c-a298-83cddd8e339b	7bd4503e-f9e5-48b0-8d2d-8704229973a7	594fb5da-c983-437d-8c6b-5965837a7a58	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-09 17:05:43.634656	c69c98b6-43d1-481d-8f30-54ff9711c7d8	active	\N	\N
d8e1f068-d567-4c38-8434-434fd168dc8b	6a64bb8c-6d69-4f2d-9e22-787a963e0bdf	f5f0890e-f9c4-4962-aa02-66a6d05c2ca4	subject	{"type": "subject"}	2025-06-10 09:43:54.657049	d4cb0f86-c7ef-4e78-bde2-b17eb4dd2d74	active	\N	\N
5cd5591e-4dc7-4a19-a31a-7081967a762e	3f884e64-247e-4bc1-80e5-8c0ffb04c732	4d0d5bf5-30cc-430c-9a44-41bc06585054	subject	{"type": "subject"}	2025-06-10 09:43:56.455564	ff38f394-539a-427c-bfdf-9c8fad88e2b0	active	\N	\N
9432bf07-14c9-41f7-b112-b4595afa154c	9b158df2-fbc1-4970-bc2a-39a4538f642e	2d7414a9-ddad-4d89-9a1b-0f1a33f0c18d	subject	{"type": "subject"}	2025-06-10 09:43:57.183593	1ba03e61-e230-49cd-a5bf-92d978d2e7d6	active	\N	\N
1a7e5bd9-0ac8-49b4-b58d-17856e7402ec	a32b5ae9-30da-4fbe-b1a0-31808b2b5cec	6a56c3eb-dd1e-4a70-b3e3-ab22b9db0aea	subject	{"type": "subject"}	2025-06-10 09:43:58.854261	d571647f-b0d9-4929-ab79-a6c81b08f207	active	\N	\N
de67a2d0-d806-48cb-aa22-221fa86285ab	dc70426a-2c58-4a87-990f-c6fcbe1ed6ae	153869aa-c579-467e-834c-9a1b3ea74807	subject	{"type": "subject"}	2025-06-10 09:44:00.435851	e0f248a6-535a-4005-b903-066681c171c2	active	\N	\N
ce42d469-79f7-459c-bbc2-7132309781d4	33a2678b-1bfc-402d-b508-1d80f4e7e8ff	47d9e7b2-300d-4cc2-8001-6b84bd68a488	subject	{"type": "subject"}	2025-06-10 09:44:02.022955	0ed420e7-2970-445a-b288-c73a80e5065d	active	\N	\N
de041abf-1bff-42a0-8f53-2f04eb0653c8	47581411-5f42-4853-a20b-68a6443f9714	c30a6635-39e1-4a42-a7b1-3a582564bdd5	subject	{"type": "subject"}	2025-06-10 10:01:39.917231	54916181-9c15-4a9e-a53c-95e49a2efe33	active	\N	\N
0e0fb576-d062-4f16-81d5-4250ad641e4f	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	f339c0bd-3364-4c50-9f04-6aabd0d0062d	subject	{"type": "subject"}	2025-06-10 10:01:41.719647	92a5a418-efbb-44c8-906b-fea9513b9f71	active	\N	\N
f436fe3a-2c17-4b0c-bc4f-540ee86920e7	8624f891-1a07-4cfe-89e0-afb4afb38abd	6ddf0b9e-9bf1-45ec-a7ba-6461df61e36e	subject	{"import": "crvs"}	2025-06-10 11:22:05.537827	51bbe452-6250-48a3-b0dc-6e0bd531a728	active	\N	\N
6b8803b2-b1cc-4908-8f5d-c8c2c5f7af07	74eeacf8-dae7-4493-a7cb-9684a1d5ae08	f9568977-54a6-4d95-a55e-5f7642a50c08	subject	{"type": "child"}	2025-06-10 11:22:09.672157	f43913bc-6845-4bf2-8d6c-f14a52b7abe2	active	\N	\N
ad49d705-911c-47e1-9fde-866a45767209	8624f891-1a07-4cfe-89e0-afb4afb38abd	f9568977-54a6-4d95-a55e-5f7642a50c08	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-10 11:22:10.906061	51bbe452-6250-48a3-b0dc-6e0bd531a728	active	\N	\N
b16a6192-e097-4af7-afb9-c94eb731933c	7b9ba74b-f18c-43ff-b9c4-3d24f434294b	8db6e53a-da20-4cb3-b9ec-75ea77f5ed84	subject	{"import": "crvs"}	2025-06-10 12:27:01.868927	e17024ca-8a07-4f0b-b963-dcd4d0bfd4c6	active	\N	\N
9f8671ef-c7ba-468d-b0d9-f106dd246386	23d32435-ed06-4469-91f9-940493fdd304	011d59a1-391f-4f4c-81e7-eb774808f280	subject	{"type": "child"}	2025-06-10 12:27:06.577177	15c4de3a-e1b8-4ad6-bf3d-e62ac7974040	active	\N	\N
f8b01b4e-9bd5-4837-a331-110f47b93a6d	7b9ba74b-f18c-43ff-b9c4-3d24f434294b	011d59a1-391f-4f4c-81e7-eb774808f280	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-10 12:27:08.163639	e17024ca-8a07-4f0b-b963-dcd4d0bfd4c6	active	\N	\N
e6c9acfd-09c8-42f3-ae33-f5b874fa9b57	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	011d59a1-391f-4f4c-81e7-eb774808f280	father	{"type": "father", "relationship": "FATHER"}	2025-06-10 13:17:44.356	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	active	\N	\N
8d79fa04-e98b-4f3b-b669-e4c2e86de09a	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	c1cc18db-5708-4799-95c5-963a9f1b1051	subject	{"type": "deceased"}	2025-06-10 13:45:24.53492	2fbd2bd3-a5d5-4f2e-847a-a7d6dc809981	active	\N	\N
87e8790a-6675-406b-a215-8b6a7aa70ed2	0d4e1123-659d-4fed-9164-6a6381fa20f3	18e4f975-6f93-43c0-af2f-5166f4785a4a	subject	{"import": "crvs"}	2025-06-10 14:33:27.764174	5c2f03a3-7fe7-4bb2-ad46-5efbf89e285a	active	\N	\N
913f0371-a63f-4f4c-8e1f-ffd0074365a8	b415f022-37ba-41b8-8400-35ee7ec50ac0	d245ee11-95d3-4aef-ad34-1b3145811385	subject	{"type": "child"}	2025-06-10 14:33:31.775499	355e9472-38d9-4e7c-8723-00786f080471	active	\N	\N
cb1dd671-c267-40ed-836a-10c378df602a	0d4e1123-659d-4fed-9164-6a6381fa20f3	d245ee11-95d3-4aef-ad34-1b3145811385	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-10 14:33:33.071859	5c2f03a3-7fe7-4bb2-ad46-5efbf89e285a	active	\N	\N
41a49d48-d4a2-43bb-b4ca-1197e43125f4	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	d245ee11-95d3-4aef-ad34-1b3145811385	father	{"type": "father", "relationship": "FATHER"}	2025-06-10 14:35:05.659	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	active	\N	\N
8661b525-049a-442a-8299-829f13358b39	2c3b0771-2f08-4d39-bc35-08282b6efc6d	eb404571-8145-4ddb-afce-14c2f1bb5947	subject	{"import": "crvs"}	2025-06-10 16:00:04.762837	fe0ca456-42d3-4b35-b156-8afbf90bb738	active	\N	\N
19f3f14f-6423-44e6-ae9b-1f8fb8abd5f6	5c97504f-92b9-4687-b551-99610cbeb507	4ea9117c-ff80-4975-a4f4-9452282d5af3	subject	{"type": "child"}	2025-06-10 16:00:08.373152	1c12e643-518e-4396-84c4-00dd95ea9b5b	active	\N	\N
2b2cb32e-ac69-498f-a307-098e6024ca52	2c3b0771-2f08-4d39-bc35-08282b6efc6d	4ea9117c-ff80-4975-a4f4-9452282d5af3	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-10 16:00:09.71352	fe0ca456-42d3-4b35-b156-8afbf90bb738	active	\N	\N
679eb439-b019-4784-ab2b-6c3c8dc59bde	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	4ea9117c-ff80-4975-a4f4-9452282d5af3	father	{"type": "father", "relationship": "FATHER"}	2025-06-10 16:01:46.708	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	active	\N	\N
04000088-113d-467f-a908-44f7d9ea4cd1	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	a06bcb9f-aafb-428d-afd5-8724895abcbc	subject	{"type": "deceased"}	2025-06-10 16:04:27.650001	ada3b919-2bd1-4934-849b-d544fd778a15	active	\N	\N
95410e48-307d-4e56-96c1-c5f97c6efc79	eda60216-a96a-48c7-b604-6c1a35c7a43b	96c851d6-98af-465b-9b29-2b106a58aca8	subject	{"import": "crvs"}	2025-06-11 08:58:11.835625	ee671587-6b10-413a-83eb-bf12864e3bd6	active	\N	\N
97b04b5a-c583-483c-af38-272002f051e6	c3505d21-bf2d-4a74-818a-d2e039963a49	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	subject	{"type": "child"}	2025-06-11 08:58:15.020599	76bcddf7-b00f-4b51-8777-e55433b8a213	active	\N	\N
3211cc44-ecee-4043-8af4-0bbe0b278ad7	eda60216-a96a-48c7-b604-6c1a35c7a43b	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-11 08:58:16.297396	ee671587-6b10-413a-83eb-bf12864e3bd6	active	\N	\N
86584670-7297-4140-a5e2-866e1663d5c6	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	father	{"type": "father", "relationship": "FATHER"}	2025-06-11 09:00:22.179	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	active	\N	\N
0686f885-6b35-446c-b774-07acd8ffc989	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	705e7d0f-c4ef-4321-a487-5348891cdd33	subject	{"type": "deceased"}	2025-06-11 09:05:17.230837	e8ef35ee-bd82-4669-afca-cfc542edad2b	active	\N	\N
f315e14a-cb57-4afd-97fc-591228c07869	497f53ef-a7e9-46dd-b183-431fea6349ab	eab4aae4-7f3a-45bd-aaca-74b3f28f8830	subject	{"type": "subject"}	2025-06-11 13:25:44.923523	668cb0f1-7430-40e3-b239-5a27861ab854	active	\N	\N
81622b4d-39dc-439c-abad-b04a2fd9fecb	6cf61010-0c15-4dde-9ef6-c0a318be7157	61470756-3d5f-4f87-8f3a-1be21e128712	subject	{"import": "crvs"}	2025-06-11 15:08:13.248457	cae6b149-f49a-40fa-80a8-9c4958be0f78	active	\N	\N
3d3c008c-c2ae-41da-9d91-3ca41487fcb4	5dd01328-55d6-4fd2-8168-a65d7311064e	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	subject	{"type": "child"}	2025-06-11 15:08:16.548591	7c2538cb-d2ff-47df-a9f4-7578165040f4	active	\N	\N
52b346c7-bdeb-484e-8cd7-c19b289eb0e4	6cf61010-0c15-4dde-9ef6-c0a318be7157	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-11 15:08:18.042281	cae6b149-f49a-40fa-80a8-9c4958be0f78	active	\N	\N
f9b06faf-f42b-4995-86fd-f9923f63d6f1	497f53ef-a7e9-46dd-b183-431fea6349ab	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	father	{"type": "father", "relationship": "FATHER"}	2025-06-11 15:12:16.219	497f53ef-a7e9-46dd-b183-431fea6349ab	active	\N	\N
d4442f0a-3d1a-4055-a75c-3c2ac64a9786	497f53ef-a7e9-46dd-b183-431fea6349ab	1ecee6bb-060f-4c2d-905f-4e447efcea69	subject	{"type": "deceased"}	2025-06-11 15:18:23.185236	69cc580c-378e-4faf-b5c3-3867aa33c99d	active	\N	\N
d1fda6b6-f3ea-41b2-a3e4-603aa8c0e0a6	1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	433c0c62-5054-4740-b106-4180628819af	subject	{"type": "subject"}	2025-06-12 08:12:48.141754	42a33433-605a-4c8d-b080-bae69173f89b	active	\N	\N
08b2962d-bd67-41c7-bedd-ce4f17ffa56b	ec69972a-e631-4ae8-8337-6354237575ad	c6c14eca-091c-48db-a5ac-9839e0277b26	subject	{"type": "subject"}	2025-06-12 08:52:43.386244	cada2820-c439-44e6-a893-3d1ac8e5c994	active	\N	\N
7e49794e-1dec-4f7c-8108-29857a8bcdc0	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	a3b38c9e-3a38-4bdc-821e-c6fc7ea21bc6	subject	{"type": "subject"}	2025-06-12 08:52:44.687694	e3a608b8-1bd6-40a5-a706-459f592fe490	active	\N	\N
e533a6f0-bf11-48b9-ad01-39d0df44e32f	ec69972a-e631-4ae8-8337-6354237575ad	313a7e96-e961-489a-b0e5-6bc0f869de17	groom	{"type": "groom"}	2025-06-12 08:52:47.886725	cada2820-c439-44e6-a893-3d1ac8e5c994	active	\N	\N
fc445515-1a57-411d-a787-8d83bb23b9eb	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	313a7e96-e961-489a-b0e5-6bc0f869de17	bride	{"type": "bride"}	2025-06-12 08:52:49.29126	e3a608b8-1bd6-40a5-a706-459f592fe490	active	\N	\N
e8cf195e-16f6-430b-85b4-e2efcf1ed3b8	d900966d-0646-4439-a658-a03055a2f96b	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	subject	{"type": "child"}	2025-06-12 09:06:55.813408	72361f81-735e-4995-94de-6c5431a88b87	active	\N	\N
77e4891c-62ab-478f-831e-6ec931660e88	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-12 09:06:57.276159	dc1fb0e2-d8f7-4821-9f66-2e0fd6d8a3d0	active	\N	\N
255c8ab9-1b90-47a5-b559-3c622b6490f7	ec69972a-e631-4ae8-8337-6354237575ad	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	father	{"type": "father", "relationship": "FATHER"}	2025-06-12 09:08:03.644	ec69972a-e631-4ae8-8337-6354237575ad	active	\N	\N
bc8df6f5-6ae5-4028-8422-c3aaea9736ed	ec69972a-e631-4ae8-8337-6354237575ad	c366b982-5f20-4b11-8288-ad2b317e6148	subject	{"type": "deceased"}	2025-06-16 12:44:09.753699	0288a03a-fb26-455d-89bc-6fa0c533dc87	active	\N	\N
1df9f5ad-82de-49a2-8e2e-c812d8564cb0	928393b4-bea8-474b-aeea-f3589e1e5bbc	d7ffabde-791e-4881-99ff-dd2129242d80	subject	{"import": "crvs"}	2025-06-17 15:09:48.241669	11714bb9-8b82-456a-a90f-a54f8d6e86b1	active	\N	\N
092591ab-bd82-448a-b6d2-b7e3cda955a1	dd3b2bdf-640c-469e-ace7-6c77d55a40e2	959058b4-19bf-4481-99a2-5d1ab4e66fd6	subject	{"type": "child"}	2025-06-17 15:09:52.158172	5e72beca-e7e2-44ea-8b01-5e0b45e0fd1d	active	\N	\N
88585e90-4cc2-4bdb-8545-1cb42ba80441	33a2678b-1bfc-402d-b508-1d80f4e7e8ff	1a092099-a402-4dcb-bb17-d6ff3afb14f0	father	{"type": "father", "relationship": "FATHER"}	2025-06-23 16:30:52.097	33a2678b-1bfc-402d-b508-1d80f4e7e8ff	active	\N	\N
6fd01768-a411-40d8-8310-805dcd0b3535	1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	959058b4-19bf-4481-99a2-5d1ab4e66fd6	father	{"type": "father", "relationship": "FATHER"}	2025-06-23 14:43:38.525	1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	active	\N	\N
f2e9736f-3d0a-4a79-8d5e-88bc6d6ce789	928393b4-bea8-474b-aeea-f3589e1e5bbc	959058b4-19bf-4481-99a2-5d1ab4e66fd6	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-17 15:09:53.078334	11714bb9-8b82-456a-a90f-a54f8d6e86b1	active	\N	\N
55327ac2-ea0b-4e27-9553-75708281b52d	15648b23-2943-4ad5-9eb6-1a64d42c52a5	b9743da3-3d58-4270-9a20-c7669694edaf	subject	{"import": "crvs"}	2025-06-23 15:32:51.813124	e84d7064-6933-450d-9c0a-9adcc2d901f7	active	\N	\N
6b0c0685-5c16-4e02-a110-7e655543d715	3e08b8ef-a8c0-492d-9bfa-7841cf539131	1a092099-a402-4dcb-bb17-d6ff3afb14f0	subject	{"type": "child"}	2025-06-23 15:32:55.453806	82a5b1a8-271e-4a07-a29e-58c0a2098dfe	active	\N	\N
d7674ff4-fce0-47b7-a9e5-d8155e9fc7b0	15648b23-2943-4ad5-9eb6-1a64d42c52a5	1a092099-a402-4dcb-bb17-d6ff3afb14f0	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-23 15:32:56.018635	e84d7064-6933-450d-9c0a-9adcc2d901f7	active	\N	\N
ab7a007a-1c41-45be-9d92-9e023ea064a0	7fd96655-c186-49cf-abad-c8c98954ea61	6b75dfb6-c6dc-4af4-beaa-c56e2dd68109	subject	{"type": "subject"}	2025-06-25 14:52:05.063301	9029eb48-1e9f-4dc9-9a19-02b686188fd7	active	\N	\N
cde1082d-7d67-4aaf-bb21-0a1bbbb02cb1	33482d70-1bdd-45fe-b205-f5f63c9cd354	45f79320-5773-4014-9bb0-d98aaf83e36a	subject	{"import": "crvs"}	2025-06-25 15:01:26.229628	944355ac-ae61-48e7-94c7-862a79102a5f	active	\N	\N
fd7da0c5-bf4b-46a6-91e5-b5ebc3a60561	ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	subject	{"type": "child"}	2025-06-25 15:01:29.979789	3f562fb1-2b34-417f-94b3-aea24ed8cac0	active	\N	\N
e7496a15-46a1-4434-a700-5842aa5871da	33482d70-1bdd-45fe-b205-f5f63c9cd354	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-25 15:01:31.191211	944355ac-ae61-48e7-94c7-862a79102a5f	active	\N	\N
a3df1f3b-44cb-442f-9311-c74cb06e5783	7fd96655-c186-49cf-abad-c8c98954ea61	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	father	{"type": "father", "relationship": "FATHER"}	2025-06-25 15:12:18.805	7fd96655-c186-49cf-abad-c8c98954ea61	active	\N	\N
9ba40537-91cd-49c6-842c-96f28f3615a2	7fd96655-c186-49cf-abad-c8c98954ea61	1e3f0009-00bd-4f7f-88cf-0fc8aacd3d9e	subject	{"type": "deceased"}	2025-06-25 15:17:49.622977	23f70c81-a6c7-418b-b28d-ebf7092fe81e	active	\N	\N
ee421560-aba3-4920-93be-3265a355266c	c60db9a2-5e82-4762-9df1-5bd27adfe8bf	35112ad7-3b3a-4119-b14c-c98a47835178	subject	{"type": "subject"}	2025-06-25 15:40:31.440472	875a9f23-d337-40d3-94ee-94a7e008ebb0	active	\N	\N
33f7a891-4855-4def-97de-bdceabcec732	f6363e55-7d9b-46e2-b08d-af3ac2c51296	1bd49fe1-bc35-4da1-b526-9fa74f8cc849	subject	{"type": "subject"}	2025-06-27 11:15:59.70663	0866ed46-6e26-493b-8cfd-c8bacf58e65f	active	\N	\N
41da51d3-30fe-4bf6-b450-df4d017acc3f	e20dece4-dc58-4b9d-96f9-9cdd1d29589a	09cfe392-6f7b-4524-bd16-3a1946bc0b84	subject	{"type": "subject"}	2025-06-27 11:16:06.291583	e10d3f04-a4a3-4de9-8e76-5cfbf99b8388	active	\N	\N
e9b1a011-2216-445f-a458-20913fe651b4	58793d93-f855-4e24-a266-d4b299697da7	f86a2d0c-9a6e-490d-be51-52f2d48088c0	subject	{"import": "crvs"}	2025-06-27 11:55:55.202295	416b02c6-97ee-4531-a917-b7cbf6ef09a7	active	\N	\N
e587f1cd-7667-4bbc-b1b2-f36eb8953218	819e7f68-e13d-4653-8623-2ff0d458d665	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	subject	{"type": "child"}	2025-06-27 11:55:58.955977	be42c002-872e-473d-8787-ec6e2ef162e8	active	\N	\N
2cce1545-725b-4583-89d6-8dfe8ccf4129	58793d93-f855-4e24-a266-d4b299697da7	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-27 11:56:00.136404	416b02c6-97ee-4531-a917-b7cbf6ef09a7	active	\N	\N
d9cd884a-b201-452f-9f9b-96b0e76785e2	c60db9a2-5e82-4762-9df1-5bd27adfe8bf	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	father	{"type": "father", "relationship": "FATHER"}	2025-06-27 12:45:17.159	c60db9a2-5e82-4762-9df1-5bd27adfe8bf	active	\N	\N
c9c5e5a3-b01e-4536-b00a-8239cddfa4c4	a6468ea7-218b-42dc-869b-23c0e074e087	53bd09af-87f4-47b4-9964-a9b810730ecb	subject	{"import": "crvs"}	2025-06-27 13:34:48.633324	31406142-9463-4ea5-a9fa-11917933beff	active	\N	\N
3a46cfd8-dc43-48f3-8286-da95cffde2d6	7fcece71-1d59-49d6-b263-30aefb340e23	d9c83380-f704-480b-8329-0cae8decc028	subject	{"type": "child"}	2025-06-27 13:34:51.928987	3ac677f0-d867-4be2-bd69-b6aab6f39eaa	active	\N	\N
0f8d5657-a226-4d59-b12c-cbb98025083f	a6468ea7-218b-42dc-869b-23c0e074e087	d9c83380-f704-480b-8329-0cae8decc028	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-27 13:34:53.344948	31406142-9463-4ea5-a9fa-11917933beff	active	\N	\N
02c74e0b-22b4-42e5-a882-87e5d8f551fc	f6363e55-7d9b-46e2-b08d-af3ac2c51296	d9c83380-f704-480b-8329-0cae8decc028	father	{"type": "father", "relationship": "FATHER"}	2025-06-27 13:43:16.782	f6363e55-7d9b-46e2-b08d-af3ac2c51296	active	\N	\N
90325a6a-d7ff-42ef-a360-5551a2855ba3	469773b9-7c6e-4901-aa92-f5d1146acc08	c2dcdb8b-da09-43f2-978e-4b570b1ba628	subject	{"import": "crvs"}	2025-06-27 19:43:57.899957	9e24b5c8-e251-4265-a7d3-b654cc84ac01	active	\N	\N
52bfb611-003e-40aa-a17f-cb8bacdc3eb5	50989c77-8345-4763-a12c-21f43d9e525f	0c65367a-189f-4411-bc9f-88cd08b9032d	subject	{"type": "child"}	2025-06-27 19:44:01.67779	06d15446-586d-43e4-8878-64ed07178a29	active	\N	\N
3b79da93-26db-4edc-8c75-566f7b27eafc	469773b9-7c6e-4901-aa92-f5d1146acc08	0c65367a-189f-4411-bc9f-88cd08b9032d	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-06-27 19:44:03.101981	9e24b5c8-e251-4265-a7d3-b654cc84ac01	active	\N	\N
161d9796-b2b9-4f84-822f-97c89b89b455	b061b4d1-30fd-4390-b663-56caa6737441	0ecb9281-2205-43d8-8620-cf37235befae	subject	{"import": "crvs"}	2025-07-18 14:47:17.320454	97c2bdb9-3f15-40e2-82cb-8da0fa9fcff8	active	\N	\N
00090c4a-7a2f-408e-81a7-f50c85c0673d	66144acd-bfc0-4501-a58d-046a2e6e0c53	7e764297-4fa1-4ff3-a687-e9b652cec5c0	subject	{"type": "child"}	2025-07-18 14:47:19.121171	6f9e8fbe-dcf5-4c4d-bf33-7028d41b6826	active	\N	\N
c15817bc-db68-4f1d-af6b-4f9d00204e6b	b061b4d1-30fd-4390-b663-56caa6737441	7e764297-4fa1-4ff3-a687-e9b652cec5c0	mother	{"type": "mother", "relationship": "MOTHER", "informantType": "MOTHER"}	2025-07-18 14:47:19.495331	97c2bdb9-3f15-40e2-82cb-8da0fa9fcff8	active	\N	\N
f8dc64b7-89ba-4960-a5ef-f2914b0421b6	e20dece4-dc58-4b9d-96f9-9cdd1d29589a	7e764297-4fa1-4ff3-a687-e9b652cec5c0	father	{"type": "father", "relationship": "FATHER"}	2025-07-18 14:54:51.082	e20dece4-dc58-4b9d-96f9-9cdd1d29589a	active	\N	\N
\.


--
-- Data for Name: family_link; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.family_link (id, person_id, related_person_id, relationship_type, relationship_subtype, source_event_id, start_date, end_date, source, notes) FROM stdin;
c70f0a7d-6860-4a65-aee5-39bd9975da76	08b6e869-9e57-41c5-adac-d9645cffc678	09361c85-ae70-4647-bcb3-269e394cfaf5	mother	\N	dad918dc-d06c-4d65-89a9-7c164d9da73c	\N	\N	OpenCRVS	Backfilled from birth event
5aba4571-0ceb-408b-91f6-e096dafbb0e5	0a9c7ec5-8a53-4562-b542-ac373339212a	679644ac-a9e5-4fdf-a974-d4d76869d193	mother	\N	e8d2e3c8-a603-4471-aea9-4dfa7fb65bce	\N	\N	OpenCRVS	Backfilled from birth event
09e7ceb8-4191-4b9b-a705-9820ad98598c	23d32435-ed06-4469-91f9-940493fdd304	7b9ba74b-f18c-43ff-b9c4-3d24f434294b	mother	\N	011d59a1-391f-4f4c-81e7-eb774808f280	\N	\N	OpenCRVS	Backfilled from birth event
b21030d3-2840-4c41-8db9-b1bcb92b715a	23d32435-ed06-4469-91f9-940493fdd304	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	father	\N	011d59a1-391f-4f4c-81e7-eb774808f280	\N	\N	OpenCRVS	Backfilled from birth event
10df5774-e5a0-498c-aa09-bc4d13edbd9a	46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	3df5bc57-427c-446c-8201-f9695bcdd6d5	mother	\N	2be67ab5-d07f-4707-b6b7-af57381bf3d2	\N	\N	OpenCRVS	Backfilled from birth event
eec2c91a-169c-4865-a228-c46b578c43a1	46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	father	\N	2be67ab5-d07f-4707-b6b7-af57381bf3d2	\N	\N	OpenCRVS	Backfilled from birth event
1f33d181-2017-4b13-b7e6-8926ab868cfb	47fb0570-8de5-4b18-b727-d10200eb5b86	3df5bc57-427c-446c-8201-f9695bcdd6d5	mother	\N	2d5e4536-80e1-4840-b456-5039c9e97882	\N	\N	OpenCRVS	Backfilled from birth event
5bc6fb63-de04-47c2-b5bc-50f00eca3f2e	4b29a876-51ff-4f4f-b8e0-6a07132f3d7f	8841bb97-3b84-443f-b9d5-1c979d5d1703	mother	\N	b283061d-a38c-48f6-8183-278d2dea1a29	\N	\N	OpenCRVS	Backfilled from birth event
98ad9860-8ba9-4bce-9bbc-cb1d588707b5	5c97504f-92b9-4687-b551-99610cbeb507	2c3b0771-2f08-4d39-bc35-08282b6efc6d	mother	\N	4ea9117c-ff80-4975-a4f4-9452282d5af3	\N	\N	OpenCRVS	Backfilled from birth event
e381107f-1cca-4afb-beee-07362afb013f	5c97504f-92b9-4687-b551-99610cbeb507	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	father	\N	4ea9117c-ff80-4975-a4f4-9452282d5af3	\N	\N	OpenCRVS	Backfilled from birth event
638896c4-322b-49bf-9b10-1491c18ca431	5dd01328-55d6-4fd2-8168-a65d7311064e	497f53ef-a7e9-46dd-b183-431fea6349ab	father	\N	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	\N	\N	OpenCRVS	Backfilled from birth event
d87ec436-0de1-4662-b89c-0504a5929443	5dd01328-55d6-4fd2-8168-a65d7311064e	6cf61010-0c15-4dde-9ef6-c0a318be7157	mother	\N	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	\N	\N	OpenCRVS	Backfilled from birth event
bc1d46a3-3a02-4d85-9c25-a57ed53b1a94	5ef5380e-2a5b-47df-a94a-d78722ba445f	f8d6bf11-3f1f-422a-8b5b-84f5c175fead	mother	\N	95f70341-5de5-4ddd-a7ba-0bc7111165c7	\N	\N	OpenCRVS	Backfilled from birth event
98b4532c-26c7-4159-bae0-570d08a8a086	69ec3c8f-aef7-4fda-9f34-22bce75e8d44	ff0ad433-88ff-4cc3-b0fe-a252290e39a2	mother	\N	5eeac30e-de18-4159-abae-9e5ccbcb06e5	\N	\N	OpenCRVS	Backfilled from birth event
bb817a52-6dde-46e4-9ca4-ee7378d0a4ec	7349640a-f9c3-4225-9a88-e8b4cbdd67d7	9bea87b9-e213-4dbb-9a66-209353cf3422	mother	\N	afd344cb-6a0c-49c2-8d88-a7ee0e2e5c7f	\N	\N	OpenCRVS	Backfilled from birth event
f2af533e-e165-4a59-93bb-d114b6e50a44	74eeacf8-dae7-4493-a7cb-9684a1d5ae08	8624f891-1a07-4cfe-89e0-afb4afb38abd	mother	\N	f9568977-54a6-4d95-a55e-5f7642a50c08	\N	\N	OpenCRVS	Backfilled from birth event
a2faa129-d509-4d44-95ae-c4ddedaaf79a	75d704fc-cd76-4dc0-afae-4bad63860665	3df5bc57-427c-446c-8201-f9695bcdd6d5	mother	\N	47ff409a-a403-4a5e-821f-9a7bab4fbe56	\N	\N	OpenCRVS	Backfilled from birth event
8c57513b-9228-418c-9717-32392e43a1bd	822298df-310a-423c-9868-baef9f74f614	060d2b75-b3ab-4e57-83ef-7a7d81f04981	mother	\N	d4c0ae9b-cf09-4fde-a665-2e34661958be	\N	\N	OpenCRVS	Backfilled from birth event
f1516142-bce4-4450-9ef6-cec9daee7dd8	876df5f7-9559-4642-bef2-2664762ab9e9	96f5df53-a65f-4a84-ae93-ca6ab71f022e	mother	\N	65aae183-361a-4098-b4a5-c57ced73498a	\N	\N	OpenCRVS	Backfilled from birth event
2cb85304-205c-46cf-8e7e-3cd47f09bbc9	92994d6d-8729-4ccf-9f05-a97bd09f1d71	3df5bc57-427c-446c-8201-f9695bcdd6d5	mother	\N	49acae79-040b-4ef4-95bb-ec67808f6ffe	\N	\N	OpenCRVS	Backfilled from birth event
111d7d71-40a6-4d8d-9a5b-65c6053c3c96	9dd7119a-7619-4ec5-b2aa-c5acf44cfc54	25f2cdab-c4fc-4693-a39d-356d4d7c79fa	mother	\N	42ac5713-2ebc-469c-92d1-15bc43da7e86	\N	\N	OpenCRVS	Backfilled from birth event
fc4a60c8-0891-4e63-8a7c-d683256b8d16	a39d188d-6df9-4d7f-b3e3-16fd26bc58dc	d3802f0d-a682-4a0e-98d9-1a8454e91590	mother	\N	1e83741c-84bb-4d7d-a00a-5581a5d8490e	\N	\N	OpenCRVS	Backfilled from birth event
1f1679a6-78e4-4207-8072-3f1d01b19236	b415f022-37ba-41b8-8400-35ee7ec50ac0	0d4e1123-659d-4fed-9164-6a6381fa20f3	mother	\N	d245ee11-95d3-4aef-ad34-1b3145811385	\N	\N	OpenCRVS	Backfilled from birth event
5ff4580b-2733-4c8b-9a4d-566695425e10	b415f022-37ba-41b8-8400-35ee7ec50ac0	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	father	\N	d245ee11-95d3-4aef-ad34-1b3145811385	\N	\N	OpenCRVS	Backfilled from birth event
5930c4ca-56a2-4ce6-abef-1c2f54b460c4	bb89dbd3-52d5-4c7d-bd99-300b9c427f9c	2399c5a9-b4a9-4e36-8532-acd6dce7ab10	mother	\N	f518405d-b545-4a4a-a379-586da42470c3	\N	\N	OpenCRVS	Backfilled from birth event
12b7c1b4-f654-43bb-bea0-412b66474956	bc8e154e-e534-4b4f-b60a-56615bdff356	5abf3659-3d05-42a1-9aa7-cab6bec3751b	mother	\N	ec4b44cf-e2b0-486b-a0e6-327288b03e09	\N	\N	OpenCRVS	Backfilled from birth event
992a2869-3b7b-45d8-9815-a6acf4c2ffeb	bf2a4ffc-e024-485c-833f-01f56912b3ac	c73dcb68-79bd-46ab-aef3-ba1a9b8b81b8	mother	\N	674fc8d3-03c7-43c9-84f8-a5365e0535e0	\N	\N	OpenCRVS	Backfilled from birth event
1cfcb10d-1c80-4813-a615-5a2a072749b9	c3505d21-bf2d-4a74-818a-d2e039963a49	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	father	\N	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	\N	\N	OpenCRVS	Backfilled from birth event
2a0de792-2a5c-47aa-afee-762be64eeb61	c3505d21-bf2d-4a74-818a-d2e039963a49	eda60216-a96a-48c7-b604-6c1a35c7a43b	mother	\N	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	\N	\N	OpenCRVS	Backfilled from birth event
2b2719f0-7518-4bad-a2b5-b0b981ee30af	d900966d-0646-4439-a658-a03055a2f96b	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	mother	\N	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	\N	\N	OpenCRVS	Backfilled from birth event
aa159c1c-9036-48ec-91e2-dd732c800eb8	d900966d-0646-4439-a658-a03055a2f96b	ec69972a-e631-4ae8-8337-6354237575ad	father	\N	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	\N	\N	OpenCRVS	Backfilled from birth event
d239d78b-74bc-467a-924c-1a7b04f7dc2d	e2f1a133-4742-4f57-8e35-905bdf7cb5ac	679644ac-a9e5-4fdf-a974-d4d76869d193	mother	\N	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	\N	\N	OpenCRVS	Backfilled from birth event
c2ddfcae-fa67-4c62-b42a-42eb25b17df4	e2f1a133-4742-4f57-8e35-905bdf7cb5ac	dd08bb18-5f3f-4479-ab18-853608ab2742	father	\N	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	\N	\N	OpenCRVS	Backfilled from birth event
72cb217e-6751-48f1-a96f-d875a02f6f05	fbdf37fc-6e9a-4c4d-b5e8-3a7c3a1535b8	3df5bc57-427c-446c-8201-f9695bcdd6d5	mother	\N	0f2c944e-e19b-42b9-8b1b-6bdf7585efe9	\N	\N	OpenCRVS	Backfilled from birth event
30db2bbd-3cbb-43a0-b346-3fde27fde574	fe2dfcd7-6675-4baf-8506-0f65c3792e19	28373367-53ba-4d6c-9881-c81b32ae4fff	mother	\N	7ebdc0f2-5eee-4b27-93c5-5bcb8624d32e	\N	\N	OpenCRVS	Backfilled from birth event
d0e582cb-58de-4c0b-9593-6e13e8518eb3	ff233649-012f-41ac-8a97-96922dae0d22	7bd4503e-f9e5-48b0-8d2d-8704229973a7	mother	\N	594fb5da-c983-437d-8c6b-5965837a7a58	\N	\N	OpenCRVS	Backfilled from birth event
bdc4b4d2-31a4-4fbf-b4ca-ee92f11d5293	09361c85-ae70-4647-bcb3-269e394cfaf5	08b6e869-9e57-41c5-adac-d9645cffc678	child	\N	dad918dc-d06c-4d65-89a9-7c164d9da73c	\N	\N	OpenCRVS	Auto-created reverse link
2deb348b-ffba-4979-8ab9-a33792e3a471	679644ac-a9e5-4fdf-a974-d4d76869d193	0a9c7ec5-8a53-4562-b542-ac373339212a	child	\N	e8d2e3c8-a603-4471-aea9-4dfa7fb65bce	\N	\N	OpenCRVS	Auto-created reverse link
f209957c-291e-45e3-993a-15cb9dd3fc64	7b9ba74b-f18c-43ff-b9c4-3d24f434294b	23d32435-ed06-4469-91f9-940493fdd304	child	\N	011d59a1-391f-4f4c-81e7-eb774808f280	\N	\N	OpenCRVS	Auto-created reverse link
402fdb6c-fac7-4326-a7cc-09ffeeec095e	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	23d32435-ed06-4469-91f9-940493fdd304	child	\N	011d59a1-391f-4f4c-81e7-eb774808f280	\N	\N	OpenCRVS	Auto-created reverse link
b494f749-b251-4eef-9e5e-f526cee1e8f1	3df5bc57-427c-446c-8201-f9695bcdd6d5	46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	child	\N	2be67ab5-d07f-4707-b6b7-af57381bf3d2	\N	\N	OpenCRVS	Auto-created reverse link
034a49a5-fe2b-47d2-859e-240637b52731	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	child	\N	2be67ab5-d07f-4707-b6b7-af57381bf3d2	\N	\N	OpenCRVS	Auto-created reverse link
b7088856-b41d-4427-ae2d-e5d907c532fd	3df5bc57-427c-446c-8201-f9695bcdd6d5	47fb0570-8de5-4b18-b727-d10200eb5b86	child	\N	2d5e4536-80e1-4840-b456-5039c9e97882	\N	\N	OpenCRVS	Auto-created reverse link
8f5efc1a-e185-4356-828a-cee29736e9dc	8841bb97-3b84-443f-b9d5-1c979d5d1703	4b29a876-51ff-4f4f-b8e0-6a07132f3d7f	child	\N	b283061d-a38c-48f6-8183-278d2dea1a29	\N	\N	OpenCRVS	Auto-created reverse link
7d6d8aa1-2a2b-4700-a0ca-5ab8c8d5a03b	2c3b0771-2f08-4d39-bc35-08282b6efc6d	5c97504f-92b9-4687-b551-99610cbeb507	child	\N	4ea9117c-ff80-4975-a4f4-9452282d5af3	\N	\N	OpenCRVS	Auto-created reverse link
60b0337f-37d5-41a4-aaea-e340f929e002	d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	5c97504f-92b9-4687-b551-99610cbeb507	child	\N	4ea9117c-ff80-4975-a4f4-9452282d5af3	\N	\N	OpenCRVS	Auto-created reverse link
17ae9817-5a99-4ef2-853f-f0c8ca40a882	497f53ef-a7e9-46dd-b183-431fea6349ab	5dd01328-55d6-4fd2-8168-a65d7311064e	child	\N	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	\N	\N	OpenCRVS	Auto-created reverse link
97876811-03a6-4709-a204-1f7fe22213e8	6cf61010-0c15-4dde-9ef6-c0a318be7157	5dd01328-55d6-4fd2-8168-a65d7311064e	child	\N	8d3e640e-63a8-4f62-bdb9-eea9bdbc01ce	\N	\N	OpenCRVS	Auto-created reverse link
0cce7bcd-359c-4176-90e6-231f8cd60e61	f8d6bf11-3f1f-422a-8b5b-84f5c175fead	5ef5380e-2a5b-47df-a94a-d78722ba445f	child	\N	95f70341-5de5-4ddd-a7ba-0bc7111165c7	\N	\N	OpenCRVS	Auto-created reverse link
236c3f9e-c729-4996-8639-7f6b533e6d18	ff0ad433-88ff-4cc3-b0fe-a252290e39a2	69ec3c8f-aef7-4fda-9f34-22bce75e8d44	child	\N	5eeac30e-de18-4159-abae-9e5ccbcb06e5	\N	\N	OpenCRVS	Auto-created reverse link
539ce954-9687-48b9-a574-1c5e552d421e	9bea87b9-e213-4dbb-9a66-209353cf3422	7349640a-f9c3-4225-9a88-e8b4cbdd67d7	child	\N	afd344cb-6a0c-49c2-8d88-a7ee0e2e5c7f	\N	\N	OpenCRVS	Auto-created reverse link
527207e1-0fc2-4f6d-9720-33e59aea68aa	8624f891-1a07-4cfe-89e0-afb4afb38abd	74eeacf8-dae7-4493-a7cb-9684a1d5ae08	child	\N	f9568977-54a6-4d95-a55e-5f7642a50c08	\N	\N	OpenCRVS	Auto-created reverse link
34de3ae8-c840-462b-a7ff-80e9298e7e78	3df5bc57-427c-446c-8201-f9695bcdd6d5	75d704fc-cd76-4dc0-afae-4bad63860665	child	\N	47ff409a-a403-4a5e-821f-9a7bab4fbe56	\N	\N	OpenCRVS	Auto-created reverse link
55d899f7-13d5-4751-8e70-575d3d29e745	060d2b75-b3ab-4e57-83ef-7a7d81f04981	822298df-310a-423c-9868-baef9f74f614	child	\N	d4c0ae9b-cf09-4fde-a665-2e34661958be	\N	\N	OpenCRVS	Auto-created reverse link
179db148-2c13-4c44-8f17-a054c0aed48b	96f5df53-a65f-4a84-ae93-ca6ab71f022e	876df5f7-9559-4642-bef2-2664762ab9e9	child	\N	65aae183-361a-4098-b4a5-c57ced73498a	\N	\N	OpenCRVS	Auto-created reverse link
29f52519-2ea8-4480-8c5f-dca09c9a0813	3df5bc57-427c-446c-8201-f9695bcdd6d5	92994d6d-8729-4ccf-9f05-a97bd09f1d71	child	\N	49acae79-040b-4ef4-95bb-ec67808f6ffe	\N	\N	OpenCRVS	Auto-created reverse link
f168d220-5f1e-418e-a4a2-777d6d9e5e88	25f2cdab-c4fc-4693-a39d-356d4d7c79fa	9dd7119a-7619-4ec5-b2aa-c5acf44cfc54	child	\N	42ac5713-2ebc-469c-92d1-15bc43da7e86	\N	\N	OpenCRVS	Auto-created reverse link
cd2acb08-a7db-4f5a-937c-cc78abeb5f7a	d3802f0d-a682-4a0e-98d9-1a8454e91590	a39d188d-6df9-4d7f-b3e3-16fd26bc58dc	child	\N	1e83741c-84bb-4d7d-a00a-5581a5d8490e	\N	\N	OpenCRVS	Auto-created reverse link
107c9adc-97a4-4844-aac7-feb2021c4263	0d4e1123-659d-4fed-9164-6a6381fa20f3	b415f022-37ba-41b8-8400-35ee7ec50ac0	child	\N	d245ee11-95d3-4aef-ad34-1b3145811385	\N	\N	OpenCRVS	Auto-created reverse link
52a8c436-cfbb-4c8a-94ac-db7c99c11cbe	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	b415f022-37ba-41b8-8400-35ee7ec50ac0	child	\N	d245ee11-95d3-4aef-ad34-1b3145811385	\N	\N	OpenCRVS	Auto-created reverse link
0ea9101a-40cf-496e-9be8-0b55d3071b0a	2399c5a9-b4a9-4e36-8532-acd6dce7ab10	bb89dbd3-52d5-4c7d-bd99-300b9c427f9c	child	\N	f518405d-b545-4a4a-a379-586da42470c3	\N	\N	OpenCRVS	Auto-created reverse link
8167f83b-073b-4fa5-bc64-9ca4c8d95ed9	5abf3659-3d05-42a1-9aa7-cab6bec3751b	bc8e154e-e534-4b4f-b60a-56615bdff356	child	\N	ec4b44cf-e2b0-486b-a0e6-327288b03e09	\N	\N	OpenCRVS	Auto-created reverse link
d3c6538a-b500-4b31-be58-59eca62829d8	c73dcb68-79bd-46ab-aef3-ba1a9b8b81b8	bf2a4ffc-e024-485c-833f-01f56912b3ac	child	\N	674fc8d3-03c7-43c9-84f8-a5365e0535e0	\N	\N	OpenCRVS	Auto-created reverse link
b4dfa651-f27b-4137-9c63-8c6aaf38305e	aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	c3505d21-bf2d-4a74-818a-d2e039963a49	child	\N	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	\N	\N	OpenCRVS	Auto-created reverse link
b797f899-533c-46bf-a4fb-c2f9ec251fc7	eda60216-a96a-48c7-b604-6c1a35c7a43b	c3505d21-bf2d-4a74-818a-d2e039963a49	child	\N	ab11b4b7-f7b6-407c-a737-c68cbad2b02b	\N	\N	OpenCRVS	Auto-created reverse link
9fcc68bb-ec4c-4c36-9c51-409b6a482c1e	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	d900966d-0646-4439-a658-a03055a2f96b	child	\N	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	\N	\N	OpenCRVS	Auto-created reverse link
d9de8d4d-fa9c-44c2-9aa1-83892c8d8079	ec69972a-e631-4ae8-8337-6354237575ad	d900966d-0646-4439-a658-a03055a2f96b	child	\N	cb456ae0-2ef7-486d-b287-f34b37a0e8b4	\N	\N	OpenCRVS	Auto-created reverse link
5f94d969-2ef7-4a2b-b21d-9b2af5d9d71b	679644ac-a9e5-4fdf-a974-d4d76869d193	e2f1a133-4742-4f57-8e35-905bdf7cb5ac	child	\N	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	\N	\N	OpenCRVS	Auto-created reverse link
8cf88f7a-f06a-4eae-8c71-7ca51e6321d7	dd08bb18-5f3f-4479-ab18-853608ab2742	e2f1a133-4742-4f57-8e35-905bdf7cb5ac	child	\N	3712771a-b05b-4d64-b1e8-f3e5dd5e477b	\N	\N	OpenCRVS	Auto-created reverse link
1c948ca6-a68c-43a0-8d11-d831c8e088e9	3df5bc57-427c-446c-8201-f9695bcdd6d5	fbdf37fc-6e9a-4c4d-b5e8-3a7c3a1535b8	child	\N	0f2c944e-e19b-42b9-8b1b-6bdf7585efe9	\N	\N	OpenCRVS	Auto-created reverse link
7f1bbb4d-77b0-41be-a897-7aadf12c9259	28373367-53ba-4d6c-9881-c81b32ae4fff	fe2dfcd7-6675-4baf-8506-0f65c3792e19	child	\N	7ebdc0f2-5eee-4b27-93c5-5bcb8624d32e	\N	\N	OpenCRVS	Auto-created reverse link
9e94499d-0f99-458d-bf4e-5439e7f73e0b	7bd4503e-f9e5-48b0-8d2d-8704229973a7	ff233649-012f-41ac-8a97-96922dae0d22	child	\N	594fb5da-c983-437d-8c6b-5965837a7a58	\N	\N	OpenCRVS	Auto-created reverse link
73e0e32e-e66c-4b7e-b792-9094d8cff5f4	ec69972a-e631-4ae8-8337-6354237575ad	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	spouse	\N	313a7e96-e961-489a-b0e5-6bc0f869de17	\N	\N	OpenCRVS	Backfilled from marriage event
bf1f4132-35f2-440e-9bc6-ff42b2709db0	dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	ec69972a-e631-4ae8-8337-6354237575ad	spouse	\N	313a7e96-e961-489a-b0e5-6bc0f869de17	\N	\N	OpenCRVS	Auto-created reverse link
5d6b4c22-7d33-4c81-a892-88765d961a98	dd3b2bdf-640c-469e-ace7-6c77d55a40e2	1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	father	\N	959058b4-19bf-4481-99a2-5d1ab4e66fd6	\N	\N	event_participant	Auto-linked from event
8f2a8590-c83c-4119-844d-bc824f27ba26	1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	dd3b2bdf-640c-469e-ace7-6c77d55a40e2	child	\N	959058b4-19bf-4481-99a2-5d1ab4e66fd6	\N	\N	event_participant	Auto-created reverse link
690d81c2-ed7e-40ef-9e62-536083e0bbd9	dd3b2bdf-640c-469e-ace7-6c77d55a40e2	928393b4-bea8-474b-aeea-f3589e1e5bbc	mother	\N	959058b4-19bf-4481-99a2-5d1ab4e66fd6	\N	\N	event_participant	Auto-linked from event
dafcd2af-feed-4686-92b9-bd0cd9e56da3	928393b4-bea8-474b-aeea-f3589e1e5bbc	dd3b2bdf-640c-469e-ace7-6c77d55a40e2	child	\N	959058b4-19bf-4481-99a2-5d1ab4e66fd6	\N	\N	event_participant	Auto-created reverse link
84024952-2a03-4739-9176-5c0d300c295d	3e08b8ef-a8c0-492d-9bfa-7841cf539131	15648b23-2943-4ad5-9eb6-1a64d42c52a5	mother	\N	1a092099-a402-4dcb-bb17-d6ff3afb14f0	\N	\N	event_participant	Auto-linked from event
d41d5178-ac3e-4081-adf7-996348af46e6	15648b23-2943-4ad5-9eb6-1a64d42c52a5	3e08b8ef-a8c0-492d-9bfa-7841cf539131	child	\N	1a092099-a402-4dcb-bb17-d6ff3afb14f0	\N	\N	event_participant	Auto-created reverse link
b4dc084a-270a-43aa-b3f4-00d5663b086f	3e08b8ef-a8c0-492d-9bfa-7841cf539131	33a2678b-1bfc-402d-b508-1d80f4e7e8ff	father	\N	1a092099-a402-4dcb-bb17-d6ff3afb14f0	\N	\N	event_participant	Auto-linked from event
9a609a0e-aef2-414c-a9db-484b9c093e43	33a2678b-1bfc-402d-b508-1d80f4e7e8ff	3e08b8ef-a8c0-492d-9bfa-7841cf539131	child	\N	1a092099-a402-4dcb-bb17-d6ff3afb14f0	\N	\N	event_participant	Auto-created reverse link
d9fdc209-c81f-44ba-8160-1a79df799e0a	ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	33482d70-1bdd-45fe-b205-f5f63c9cd354	mother	\N	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	\N	\N	event_participant	Auto-linked from event
34498367-1a66-44b7-81b2-f6d4b9bbdaf4	33482d70-1bdd-45fe-b205-f5f63c9cd354	ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	child	\N	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	\N	\N	event_participant	Auto-created reverse link
176ebd20-4fd2-4d5d-b70d-b11fcbd5b240	ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	7fd96655-c186-49cf-abad-c8c98954ea61	father	\N	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	\N	\N	event_participant	Auto-linked from event
425a0e7f-1421-427e-ab9f-24101ab810ed	7fd96655-c186-49cf-abad-c8c98954ea61	ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	child	\N	9cca0620-2d6d-43fb-a98f-f2b426ffc9a7	\N	\N	event_participant	Auto-created reverse link
91eebd59-8c45-4aa6-b4af-7aa649911072	819e7f68-e13d-4653-8623-2ff0d458d665	58793d93-f855-4e24-a266-d4b299697da7	mother	\N	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	\N	\N	event_participant	Auto-linked from event
a1ef3c78-3919-4cf1-b944-4d77572fc67a	58793d93-f855-4e24-a266-d4b299697da7	819e7f68-e13d-4653-8623-2ff0d458d665	child	\N	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	\N	\N	event_participant	Auto-created reverse link
19c90f75-1a75-4afc-a4b5-99e3fbb40404	819e7f68-e13d-4653-8623-2ff0d458d665	c60db9a2-5e82-4762-9df1-5bd27adfe8bf	father	\N	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	\N	\N	event_participant	Auto-linked from event
86557ee9-6800-4ac0-87ed-96c500024d22	c60db9a2-5e82-4762-9df1-5bd27adfe8bf	819e7f68-e13d-4653-8623-2ff0d458d665	child	\N	d8eccbcf-77c3-49e0-80b2-6a735f22ee20	\N	\N	event_participant	Auto-created reverse link
4d039f81-b938-4c3b-bc19-09341f6b9263	7fcece71-1d59-49d6-b263-30aefb340e23	a6468ea7-218b-42dc-869b-23c0e074e087	mother	\N	d9c83380-f704-480b-8329-0cae8decc028	\N	\N	event_participant	Auto-linked from event
b35a7ca3-b007-453b-bf74-88557c2a6915	a6468ea7-218b-42dc-869b-23c0e074e087	7fcece71-1d59-49d6-b263-30aefb340e23	child	\N	d9c83380-f704-480b-8329-0cae8decc028	\N	\N	event_participant	Auto-created reverse link
b5da8305-6bd3-4736-a6ce-66f05e26242f	7fcece71-1d59-49d6-b263-30aefb340e23	f6363e55-7d9b-46e2-b08d-af3ac2c51296	father	\N	d9c83380-f704-480b-8329-0cae8decc028	\N	\N	event_participant	Auto-linked from event
5d7a8bf4-726e-4d29-8eef-33cb2e815695	f6363e55-7d9b-46e2-b08d-af3ac2c51296	7fcece71-1d59-49d6-b263-30aefb340e23	child	\N	d9c83380-f704-480b-8329-0cae8decc028	\N	\N	event_participant	Auto-created reverse link
3214e260-1d8a-43a9-b4ff-ac49e7892288	50989c77-8345-4763-a12c-21f43d9e525f	469773b9-7c6e-4901-aa92-f5d1146acc08	mother	\N	0c65367a-189f-4411-bc9f-88cd08b9032d	\N	\N	event_participant	Auto-linked from event
b8d14838-63ff-4ec1-9b4d-0a0fd2a28c15	469773b9-7c6e-4901-aa92-f5d1146acc08	50989c77-8345-4763-a12c-21f43d9e525f	child	\N	0c65367a-189f-4411-bc9f-88cd08b9032d	\N	\N	event_participant	Auto-created reverse link
0b30d44c-72bf-4dbf-9630-975d248ed556	66144acd-bfc0-4501-a58d-046a2e6e0c53	b061b4d1-30fd-4390-b663-56caa6737441	mother	\N	7e764297-4fa1-4ff3-a687-e9b652cec5c0	\N	\N	event_participant	Auto-linked from event
152a024e-3f4e-4b92-8f20-0f5f7cd4c5b0	b061b4d1-30fd-4390-b663-56caa6737441	66144acd-bfc0-4501-a58d-046a2e6e0c53	child	\N	7e764297-4fa1-4ff3-a687-e9b652cec5c0	\N	\N	event_participant	Auto-created reverse link
a9cec470-437c-4e1f-8e6b-dc8d01169ba2	66144acd-bfc0-4501-a58d-046a2e6e0c53	e20dece4-dc58-4b9d-96f9-9cdd1d29589a	father	\N	7e764297-4fa1-4ff3-a687-e9b652cec5c0	\N	\N	event_participant	Auto-linked from event
b4d69940-4900-46da-a68c-572dd6f25483	e20dece4-dc58-4b9d-96f9-9cdd1d29589a	66144acd-bfc0-4501-a58d-046a2e6e0c53	child	\N	7e764297-4fa1-4ff3-a687-e9b652cec5c0	\N	\N	event_participant	Auto-created reverse link
\.


--
-- Data for Name: person; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.person (id, given_name, family_name, gender, dob, place_of_birth, identifiers, status, created_at, updated_at, death_date) FROM stdin;
25f2cdab-c4fc-4693-a39d-356d4d7c79fa	Robert	Cole	female	1972-03-22	Port Lindachester	[{"type": "NIN", "value": "349-36-2548"}]	active	2025-05-13 13:45:46.011454	2025-05-13 13:45:46.011454	\N
854e958a-b6b7-44d1-8795-da54dab59c84	Brandon	Perez	male	1973-09-30	Port Jesseville	[{"type": "NIN", "value": "390-36-7429"}]	active	2025-05-13 13:45:46.029302	2025-05-13 13:45:46.029302	\N
e1148e47-a783-4516-b041-abd642405c7c	Chelsea	Jackson	male	1967-09-06	South Noah	[{"type": "NIN", "value": "656-89-9126"}]	active	2025-05-13 13:45:46.037632	2025-05-13 13:45:46.037632	\N
8e7ec9cf-a941-46a6-9e0b-1aaee0d74e10	Jeffrey	Nguyen	unknown	1941-12-22	Port Antonio	[{"type": "NIN", "value": "324-52-4387"}]	active	2025-05-13 13:45:46.041829	2025-05-13 13:45:46.041829	\N
bb44ff20-8ed4-42c1-9901-4322e4b4c561	Carl	Gentry	unknown	2011-07-22	Jasonfort	[{"type": "NIN", "value": "406-83-7518"}]	deceased	2025-05-13 13:45:46.046825	2025-05-13 13:45:46.046825	\N
0bba79ee-cc6a-4953-aa72-897a18dc0967	Douglas	Taylor	male	2010-10-06	Juliechester	[{"type": "NIN", "value": "598-52-5931"}]	active	2025-05-13 13:45:46.071067	2025-05-13 13:45:46.071067	\N
8824f3ca-aaf9-43de-9960-6e0c32db6181	Jeffrey	Bright	unknown	2003-09-16	Daviston	[{"type": "NIN", "value": "882-15-2505"}]	deceased	2025-05-13 13:45:46.075165	2025-05-13 13:45:46.075165	\N
bffaaa11-4ddb-4928-9edf-8b8618087db7	Courtney	Conner	other	1991-10-26	South Patrickmouth	[{"type": "NIN", "value": "542-33-9065"}]	active	2025-05-13 13:45:46.079188	2025-05-13 13:45:46.079188	\N
4957eabe-96c3-490f-8985-f8eda8833b9b	Michelle	Smith	female	1949-12-14	Kaylamouth	[{"type": "NIN", "value": "115-38-7124"}]	deceased	2025-05-13 13:45:46.082631	2025-05-13 13:45:46.082631	\N
40dbe816-0c48-418a-a2fa-eff40a829fe1	Eric	Smith	male	1970-03-18	New Rita	[{"type": "NIN", "value": "892-81-4890"}]	active	2025-05-13 13:45:46.085936	2025-05-13 13:45:46.085936	\N
3d6540c3-aa32-4f9c-9fe0-d62aba496731	Meagan	Romero	unknown	1961-06-07	West Kathryn	[{"type": "NIN", "value": "553-68-0010"}]	active	2025-05-13 13:45:46.089446	2025-05-13 13:45:46.089446	\N
fa34a844-b81a-4ed0-aa9e-3e311cfd3ad8	Carol	Burns	other	1949-08-02	Natashaport	[{"type": "NIN", "value": "246-08-3947"}]	deceased	2025-05-13 13:45:46.093474	2025-05-13 13:45:46.093474	\N
3c6a948d-cc5c-4efc-9e2a-525c49b5321c	Natalie	Arroyo	other	1946-01-07	Cabreraside	[{"type": "NIN", "value": "785-17-2104"}]	active	2025-05-13 13:45:46.100304	2025-05-13 13:45:46.100304	\N
b7987a2f-e8ec-43ac-bdbc-2ce706f15138	Donna	Arroyo	unknown	1956-11-01	Allisonchester	[{"type": "NIN", "value": "217-70-3296"}]	active	2025-05-13 13:45:46.104677	2025-05-13 13:45:46.104677	\N
35bf5c76-2752-4a55-9818-c0523877f0bd	Jennifer	Ross	unknown	2022-10-23	Samuelhaven	[{"type": "NIN", "value": "463-16-4062"}]	active	2025-05-13 13:45:46.109801	2025-05-13 13:45:46.109801	\N
688e2e7f-1876-47cc-9bd5-be46389f2a75	Kevin	Tsang	male	2025-05-13	Hong Kong	[{"type": "NIN", "value": "123-46-2345"}]	active	2025-05-13 14:32:44.789833	2025-05-13 14:32:44.789833	\N
fbdf37fc-6e9a-4c4d-b5e8-3a7c3a1535b8	Kevin	Child2	male	2025-05-01	Health Institution, Fikombo HP	[{"type": "NATIONAL_ID", "value": "2025BR8ICR5"}, {"type": "crvs", "value": "1347ef35-b6b4-41b6-80ba-e4ad936563ab"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BR8ICR5"}]	active	2025-05-29 13:12:43.886521	2025-05-29 13:12:43.886521	\N
46d53bb1-69cd-4b90-ba39-2f13d8eed0ca	Kevin	Child9	male	2025-05-10	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BY3JSJC"}, {"type": "crvs", "value": "39dc1319-1b5d-449d-a395-13259ca0151e"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BY3JSJC"}]	active	2025-05-29 13:15:20.768419	2025-05-29 13:15:20.768419	\N
92994d6d-8729-4ccf-9f05-a97bd09f1d71	Lily	Jackson	female	2025-06-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BRUWXNY"}, {"type": "crvs", "value": "cbb8d306-731e-4197-a380-cc280068ed72"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BRUWXNY"}]	active	2025-06-02 11:08:34.102221	2025-06-02 11:08:34.102221	\N
47fb0570-8de5-4b18-b727-d10200eb5b86	Daisy	Davidson	female	2025-05-28	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BWHUBJ1"}, {"type": "crvs", "value": "618f0518-e28a-4a05-a723-edb3e88e3e87"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BWHUBJ1"}]	active	2025-06-02 11:22:26.986299	2025-06-02 11:22:26.986299	\N
75d704fc-cd76-4dc0-afae-4bad63860665	Raymond	Ware	male	2024-05-03	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BI26CR3"}, {"type": "crvs", "value": "bb2c0cd3-7544-486a-b291-b76a83e17e32"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BI26CR3"}]	active	2025-06-02 11:50:09.545822	2025-06-02 11:50:09.545822	\N
9dd7119a-7619-4ec5-b2aa-c5acf44cfc54	Kelvin	Dickson	male	2025-05-24	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BHQJ4LW"}, {"type": "crvs", "value": "bdb15741-bb7c-4b76-9c4c-62aa0de6d907"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BHQJ4LW"}]	active	2025-06-02 19:35:42.411159	2025-06-02 19:35:42.411159	\N
c1086b38-4968-4eba-93f0-6a0c310d4d58	Kevin	Child2	male	2025-05-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "UNKNOWN"}, {"type": "crvs", "value": "3d3b030a-665a-49b0-aaab-a3195473bca1"}]	active	2025-06-03 21:27:18.335603	2025-06-03 21:27:18.335603	\N
679644ac-a9e5-4fdf-a974-d4d76869d193	Mother	Child2	female	1985-01-01	Kaylamouth	[{"type": "NATIONAL_ID", "value": "0012345678"}, {"type": "crvs", "value": "d16e43d1-8727-43d5-8086-932463bb79d7"}]	active	2025-05-13 13:45:46.082631	2025-05-13 13:45:46.082631	\N
3df5bc57-427c-446c-8201-f9695bcdd6d5	Mother	Child9	female	1984-09-28	Jasonview	[{"type": "NATIONAL_ID", "value": "1234567890"}, {"type": "crvs", "value": "f6a2de58-b176-49f7-b2cc-0465898a7b7b"}]	active	2025-05-13 13:45:46.033517	2025-05-13 13:45:46.033517	\N
59792677-8eb1-4c52-8125-08c86a9ea68a	Simon	Wong	male	1955-05-01	Hong Kong	[{"type": "HKID", "value": "A12345670"}, {"type": "crvs", "value": "dd08bb18-5f3f-4479-ab18-853608ab2745"}]	active	2025-05-13 14:32:45.132586	2025-05-13 14:32:45.132586	\N
d3802f0d-a682-4a0e-98d9-1a8454e91590	Mother	Child3	female	1985-01-01	1 Village Area, Town, Isamba, FAR	[{"type": "NATIONAL_ID", "value": "1234567899"}, {"type": "crvs", "value": "d16e43d1-8727-43d5-8086-932463bb79d7"}]	active	2025-05-13 13:45:46.033517	2025-05-13 13:45:46.033517	\N
a39d188d-6df9-4d7f-b3e3-16fd26bc58dc	Kevin	Child3	male	2025-05-01	Unknown, FAR	[{"type": "NATIONAL_ID", "value": "2025BWLNXIV"}, {"type": "crvs", "value": "8b9e3880-7fc5-4cda-bbf2-0a478cec6c2a"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BWLNXIV"}]	active	2025-06-04 10:59:56.071775	2025-06-04 10:59:56.071775	\N
0a9c7ec5-8a53-4562-b542-ac373339212a	Kevin	Child2	male	2025-05-01	Unknown, FAR	[{"type": "NATIONAL_ID", "value": "UNKNOWN"}, {"type": "crvs", "value": "3d3b030a-665a-49b0-aaab-a3195473bca1"}]	active	2025-06-04 12:01:41.720716	2025-06-04 12:01:41.720716	\N
e2f1a133-4742-4f57-8e35-905bdf7cb5ac	Demo	Child 1	male	2025-06-04	Unknown, FAR	[{"type": "NATIONAL_ID", "value": "UNKNOWN"}, {"type": "crvs", "value": "98ab16ac-4272-40ec-ab45-c4737d8ff6b4"}]	active	2025-06-05 21:37:33.532946	2025-06-05 21:37:33.532946	\N
9da4f95a-3bdb-42c5-a55b-916779251185	Christopher	Henderson	other	1938-06-02	East Jessetown	[{"type": "NATIONAL_ID", "value": "5752689290"}]	active	2025-05-13 13:45:46.002645	2025-05-13 13:45:46.002645	\N
7a6633f5-3186-4222-b7a2-32c9738637e5	Jessica	Herrera	unknown	1985-11-18	New Kellystad	[{"type": "NATIONAL_ID", "value": "5922511400"}, {"type": "crvs", "event": "death", "value": "0455e8f0-88a7-4ce6-addf-bd65f54c7a01"}, {"type": "NATIONAL_ID", "value": "5922511400"}]	deceased	2025-05-13 13:45:46.024351	2025-06-09 13:20:09.228	2025-06-03
2399c5a9-b4a9-4e36-8532-acd6dce7ab10	Kevin	Child1	female	1985-01-01	Unknown	[{"type": "crvs", "value": "9c4ce4a2-d4b3-45ac-9274-a18ce5a672de"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-06 13:51:35.069679	2025-06-06 13:51:35.069679	\N
bb89dbd3-52d5-4c7d-bd99-300b9c427f9c	Kevin	Child1	male	2025-05-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BYDEB70"}, {"type": "crvs", "value": "40d3afad-31bf-4776-92fa-ca1a22707dff"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BYDEB70"}]	active	2025-06-06 13:51:39.280603	2025-06-06 13:51:39.280603	\N
f8d6bf11-3f1f-422a-8b5b-84f5c175fead	Mother	Demo 2	female	1985-01-01	Unknown	[{"type": "crvs", "value": "bdf727d8-4bf3-458c-8538-0a8e73e25a93"}, {"type": "NATIONAL_ID", "value": "2468135790"}]	review	2025-06-06 13:51:46.451487	2025-06-06 13:51:46.451487	\N
5ef5380e-2a5b-47df-a94a-d78722ba445f	Baby	Test 1	male	2025-06-06	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BSKQOAU"}, {"type": "crvs", "value": "0f607877-405d-4673-80b8-4c11226343e2"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BSKQOAU"}]	active	2025-06-06 13:51:50.68229	2025-06-06 13:51:50.68229	\N
dd08bb18-5f3f-4479-ab18-853608ab2742	Danielle	Johnson	male	1971-10-17	East Donald	[{"type": "NATIONAL_ID", "value": "1058789360"}, {"type": "crvs", "event": "birth", "value": "82fcf06c-9570-476b-bdbb-ef51fa39111e"}, {"type": "crvs", "event": "death", "value": "c9a7e2e1-2bf8-4899-a9a5-5423a9c65b6e"}, {"type": "NATIONAL_ID", "value": "1058789360"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DOCWVD7"}]	deceased	2025-05-13 13:45:45.98358	2025-06-09 12:50:40.968	2025-06-05
ff0ad433-88ff-4cc3-b0fe-a252290e39a2	Mother	Child2	female	1985-01-01	Unknown	[{"type": "crvs", "value": "e80a3f4c-338a-48d6-a4de-dc3e8990c137"}, {"type": "NATIONAL_ID", "value": "0012345678"}]	review	2025-06-09 15:10:47.238733	2025-06-09 15:10:47.238733	\N
69ec3c8f-aef7-4fda-9f34-22bce75e8d44	Kevin	Child9	male	2025-05-10	Town, FAR	[{"type": "NATIONAL_ID", "value": "UNKNOWN"}, {"type": "crvs", "value": "5f0cdcd0-106d-43c7-ae1f-87a4a32930bf"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BMVXRTH"}]	active	2025-06-09 15:10:50.504938	2025-06-09 15:10:50.504938	\N
28373367-53ba-4d6c-9881-c81b32ae4fff	Mother	Child8	female	1985-01-01	Unknown	[{"type": "crvs", "value": "700e681a-0a88-46c3-8dd5-a9ab71ab5adb"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 15:10:57.557554	2025-06-09 15:10:57.557554	\N
fe2dfcd7-6675-4baf-8506-0f65c3792e19	Kevin	Child81	male	2025-05-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BSFPTIV"}, {"type": "crvs", "value": "4bdf55bc-a555-4de1-ab84-22820373e290"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BSFPTIV"}]	active	2025-06-09 15:11:01.359377	2025-06-09 15:11:01.359377	\N
c73dcb68-79bd-46ab-aef3-ba1a9b8b81b8	Mother	Child1	female	1985-01-01	Unknown	[{"type": "crvs", "value": "7002ee2e-5416-4564-9f75-fde3f9a42018"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 15:11:07.713089	2025-06-09 15:11:07.713089	\N
bf2a4ffc-e024-485c-833f-01f56912b3ac	Kevin	Child5	male	2025-05-01	Health Institution, Fikombo HP	[{"type": "NATIONAL_ID", "value": "2025BAGM5A9"}, {"type": "crvs", "value": "c16b34df-92bc-433c-a67e-a4d9474bb2ef"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BAGM5A9"}]	active	2025-06-09 15:11:17.331813	2025-06-09 15:11:17.331813	\N
96f5df53-a65f-4a84-ae93-ca6ab71f022e	Mother	Child1	female	1985-01-01	Unknown	[{"type": "crvs", "value": "2706c226-65c4-41ed-92e3-16fa1d63dc0a"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 15:11:45.758916	2025-06-09 15:11:45.758916	\N
876df5f7-9559-4642-bef2-2664762ab9e9	Kevin	Child4	male	2025-05-01	Health Institution, Fikombo HP	[{"type": "NATIONAL_ID", "value": "2025BYVH4ZB"}, {"type": "crvs", "value": "0983eddb-3d7c-4ebc-931d-dcef267b69ff"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BYVH4ZB"}]	active	2025-06-09 15:11:49.757537	2025-06-09 15:11:49.757537	\N
09361c85-ae70-4647-bcb3-269e394cfaf5	Mother	Child7	female	1985-01-01	Unknown	[{"type": "crvs", "value": "f57172bc-6449-465d-bbff-25ada3177546"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 15:11:58.155402	2025-06-09 15:11:58.155402	\N
08b6e869-9e57-41c5-adac-d9645cffc678	Kevin	Child	male	2025-05-01	Health Institution, Fulaza Rural Health Centre	[{"type": "NATIONAL_ID", "value": "2025BTTQNFQ"}, {"type": "crvs", "value": "710f2957-920a-4272-8c8b-86d6b5a3f49d"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BTTQNFQ"}]	active	2025-06-09 15:12:02.115114	2025-06-09 15:12:02.115114	\N
8841bb97-3b84-443f-b9d5-1c979d5d1703	Mother	Child3	female	1985-01-01	Unknown	[{"type": "crvs", "value": "ccdfb332-8cde-41d5-ba6a-c9990cb99b8d"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 15:12:08.366213	2025-06-09 15:12:08.366213	\N
4b29a876-51ff-4f4f-b8e0-6a07132f3d7f	Kevin	Child6	male	2025-05-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BXGXIXD"}, {"type": "crvs", "value": "dfc97244-fb52-40b6-bb71-cb1c2e7501be"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BXGXIXD"}]	active	2025-06-09 15:12:12.246886	2025-06-09 15:12:12.246886	\N
5abf3659-3d05-42a1-9aa7-cab6bec3751b	Mother	Child2	female	1985-01-01	Unknown	[{"type": "crvs", "value": "46281ccc-4919-4063-b282-c6daa9ec1ce2"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-09 16:54:06.342398	2025-06-09 16:54:06.342398	\N
bc8e154e-e534-4b4f-b60a-56615bdff356	Kevin	Child2	male	2025-01-01	Health Institution, Fikombo HP	[{"type": "NATIONAL_ID", "value": "2025B8BAMHS"}, {"type": "crvs", "value": "f2bc13c2-022b-4f1a-81ab-1aa09e63dd64"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025B8BAMHS"}]	active	2025-06-09 16:54:09.880309	2025-06-09 16:54:09.880309	\N
060d2b75-b3ab-4e57-83ef-7a7d81f04981	Mother	LastN	female	1981-01-01	Unknown	[{"type": "crvs", "value": "649afb85-4e3b-48c4-95c4-27916a175ad7"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-1"}]	review	2025-06-09 17:05:08.732774	2025-06-09 17:05:08.732774	\N
822298df-310a-423c-9868-baef9f74f614	Demo Child	LastN	male	2025-05-05	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025B4RXRSR"}, {"type": "crvs", "value": "dfd4ef95-0f52-401c-856b-0839b0665f8b"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025B4RXRSR"}]	active	2025-06-09 17:05:14.035768	2025-06-09 17:05:14.035768	\N
9bea87b9-e213-4dbb-9a66-209353cf3422	Mother	LastN	female	1985-01-01	Unknown	[{"type": "crvs", "value": "1418d6cf-aacb-45cb-8b47-bd86e6c2aaa0"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-1"}]	review	2025-06-09 17:05:23.39774	2025-06-09 17:05:23.39774	\N
7349640a-f9c3-4225-9a88-e8b4cbdd67d7	Raymond	Child 1	male	2025-06-05	Town, FAR	[{"type": "NATIONAL_ID", "value": "UNKNOWN"}, {"type": "crvs", "value": "cb5ec1a4-91df-43a0-af29-95fd3b248d04"}]	active	2025-06-09 17:05:27.536766	2025-06-09 17:05:27.536766	\N
ff233649-012f-41ac-8a97-96922dae0d22	Ray	Son	male	2025-06-06	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BHT4UAC"}, {"type": "crvs", "value": "1c9f8ba0-b28f-46bb-ba6b-0eae877187dd"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BHT4UAC"}]	active	2025-06-09 17:05:39.209273	2025-06-09 17:05:39.209273	\N
7bd4503e-f9e5-48b0-8d2d-8704229973a7	Ray Mother	Son	female	1985-01-01	Unknown	[{"type": "crvs", "value": "c69c98b6-43d1-481d-8f30-54ff9711c7d8"}, {"type": "NATIONAL_ID", "value": "1212121212"}]	active	2025-06-09 17:05:34.023272	2025-06-09 17:05:34.023272	\N
6a64bb8c-6d69-4f2d-9e22-787a963e0bdf	Emma	Wilson	female	1998-03-12	London, UK	[{"type": "crvs", "event": "birth", "value": "d4cb0f86-c7ef-4e78-bde2-b17eb4dd2d74"}, {"type": "NATIONAL_ID", "value": "NID-v7efyzha2"}]	active	2025-06-10 09:43:31.912526	2025-06-10 09:43:31.912526	\N
3f884e64-247e-4bc1-80e5-8c0ffb04c732	Liam	Patel	male	2001-07-25	New York, USA	[{"type": "crvs", "event": "birth", "value": "ff38f394-539a-427c-bfdf-9c8fad88e2b0"}, {"type": "NATIONAL_ID", "value": "NID-zu5srog1m"}]	active	2025-06-10 09:43:33.592542	2025-06-10 09:43:33.592542	\N
9b158df2-fbc1-4970-bc2a-39a4538f642e	Sophia	Chen	female	1995-11-03	Tokyo, Japan	[{"type": "crvs", "event": "birth", "value": "1ba03e61-e230-49cd-a5bf-92d978d2e7d6"}, {"type": "NATIONAL_ID", "value": "NID-of6fmqywg"}]	active	2025-06-10 09:43:35.096685	2025-06-10 09:43:35.096685	\N
a32b5ae9-30da-4fbe-b1a0-31808b2b5cec	Noah	Martin	male	2003-04-08	Paris, France	[{"type": "crvs", "event": "birth", "value": "d571647f-b0d9-4929-ab79-a6c81b08f207"}, {"type": "NATIONAL_ID", "value": "NID-l7p5oadl7"}]	active	2025-06-10 09:43:38.991907	2025-06-10 09:43:38.991907	\N
dc70426a-2c58-4a87-990f-c6fcbe1ed6ae	Olivia	Garcia	female	1999-09-30	Sydney, Australia	[{"type": "crvs", "event": "birth", "value": "e0f248a6-535a-4005-b903-066681c171c2"}, {"type": "NATIONAL_ID", "value": "NID-3k2pmyzdl"}]	active	2025-06-10 09:43:41.001275	2025-06-10 09:43:41.001275	\N
33a2678b-1bfc-402d-b508-1d80f4e7e8ff	Ray	Father	male	1983-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "0ed420e7-2970-445a-b288-c73a80e5065d"}, {"type": "NATIONAL_ID", "value": "NID-dvswk7kha"}]	active	2025-06-10 09:43:42.996684	2025-06-10 09:43:42.996684	\N
47581411-5f42-4853-a20b-68a6443f9714	Kinson	Pat Father	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "54916181-9c15-4a9e-a53c-95e49a2efe33"}, {"type": "NATIONAL_ID", "value": "2932048047"}]	active	2025-06-10 10:01:31.073478	2025-06-10 10:01:31.073478	\N
8624f891-1a07-4cfe-89e0-afb4afb38abd	Ray Mother	Son	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "51bbe452-6250-48a3-b0dc-6e0bd531a728"}, {"type": "NATIONAL_ID", "value": "1212121212"}]	review	2025-06-10 11:22:02.332765	2025-06-10 11:22:02.332765	\N
74eeacf8-dae7-4493-a7cb-9684a1d5ae08	Ray	Son	male	2025-06-06	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BTABWXZ"}, {"type": "crvs", "event": "birth", "value": "f43913bc-6845-4bf2-8d6c-f14a52b7abe2"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BTABWXZ"}]	active	2025-06-10 11:22:07.034507	2025-06-10 11:22:07.034507	\N
7b9ba74b-f18c-43ff-b9c4-3d24f434294b	Jason Mother	Tom	female	1970-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "e17024ca-8a07-4f0b-b963-dcd4d0bfd4c6"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-0"}]	review	2025-06-10 12:26:58.470463	2025-06-10 12:26:58.470463	\N
23d32435-ed06-4469-91f9-940493fdd304	Jackson	Tom	male	2025-06-07	Health Institution, Ibombo Rural Health Centre	[{"type": "NATIONAL_ID", "value": "2025BCKPAT0"}, {"type": "crvs", "event": "birth", "value": "15c4de3a-e1b8-4ad6-bf3d-e62ac7974040"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BCKPAT0"}]	active	2025-06-10 12:27:03.370031	2025-06-10 12:27:03.370031	\N
0d4e1123-659d-4fed-9164-6a6381fa20f3	Mother	Load Test	female	1949-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "5c2f03a3-7fe7-4bb2-ad46-5efbf89e285a"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-10 14:33:25.869617	2025-06-10 14:33:25.869617	\N
b415f022-37ba-41b8-8400-35ee7ec50ac0	Child	Load Test	male	2025-06-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BYW6OWN"}, {"type": "crvs", "event": "birth", "value": "355e9472-38d9-4e7c-8723-00786f080471"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BYW6OWN"}]	active	2025-06-10 14:33:29.068122	2025-06-10 14:33:29.068122	\N
2c3b0771-2f08-4d39-bc35-08282b6efc6d	Mother	Demo 3	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "fe0ca456-42d3-4b35-b156-8afbf90bb738"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-9"}]	review	2025-06-10 16:00:00.794713	2025-06-10 16:00:00.794713	\N
5c97504f-92b9-4687-b551-99610cbeb507	Child	For Demo 	male	2025-06-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BO4W98H"}, {"type": "crvs", "event": "birth", "value": "1c12e643-518e-4396-84c4-00dd95ea9b5b"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BO4W98H"}]	active	2025-06-10 16:00:05.475739	2025-06-10 16:00:05.475739	\N
d57d9ebd-1cd3-4745-8b9e-00d9de9f1a2c	Jason	Gallagher	male	1948-04-09	South Colinstad	[{"type": "NATIONAL_ID", "value": "1357924680"}, {"type": "crvs", "value": "7f0b7f3c-e8d3-4f39-9fda-71b1a65eda5a"}, {"type": "crvs", "event": "death", "value": "ada3b919-2bd1-4934-849b-d544fd778a15"}, {"type": "NATIONAL_ID", "value": "1357924680"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DCIWZXR"}]	deceased	2025-05-13 13:45:46.019962	2025-06-10 16:04:23.38	2025-06-01
eda60216-a96a-48c7-b604-6c1a35c7a43b	Mother Demo	Quick	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "ee671587-6b10-413a-83eb-bf12864e3bd6"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-8"}]	review	2025-06-11 08:58:09.03387	2025-06-11 08:58:09.03387	\N
c3505d21-bf2d-4a74-818a-d2e039963a49	Child Demo	Quick	male	2025-06-01	Health Institution, Ibombo Rural Health Centre	[{"type": "NATIONAL_ID", "value": "2025BZUPA93"}, {"type": "crvs", "event": "birth", "value": "76bcddf7-b00f-4b51-8777-e55433b8a213"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BZUPA93"}]	active	2025-06-11 08:58:12.460342	2025-06-11 08:58:12.460342	\N
6cf61010-0c15-4dde-9ef6-c0a318be7157	Mary Mother	Lee	female	1970-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "cae6b149-f49a-40fa-80a8-9c4958be0f78"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-1"}]	review	2025-06-11 15:08:10.181858	2025-06-11 15:08:10.181858	\N
aca76b28-ce95-4ab1-b5cb-74bc59e2f2e6	Jackson	Tom Father	male	1969-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "92a5a418-efbb-44c8-906b-fea9513b9f71"}, {"type": "NATIONAL_ID", "value": "9914720412"}, {"type": "crvs", "event": "death", "value": "2fbd2bd3-a5d5-4f2e-847a-a7d6dc809981"}, {"type": "NATIONAL_ID", "value": "9914720412"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DWOUTYA"}, {"type": "crvs", "event": "death", "value": "e8ef35ee-bd82-4669-afca-cfc542edad2b"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025D05PMMQ"}, {"type": "NATIONAL_ID", "value": "9914720412"}, {"type": "NATIONAL_ID", "value": "9914720412"}]	deceased	2025-06-10 10:01:33.117767	2025-06-11 09:05:12.566	2025-06-05
5dd01328-55d6-4fd2-8168-a65d7311064e	Mary	Lee	female	2025-06-10	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BAF1XQJ"}, {"type": "crvs", "event": "birth", "value": "7c2538cb-d2ff-47df-a9f4-7578165040f4"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BAF1XQJ"}]	active	2025-06-11 15:08:13.894244	2025-06-11 15:08:13.894244	\N
497f53ef-a7e9-46dd-b183-431fea6349ab	Mary Father	Lee	male	1969-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "668cb0f1-7430-40e3-b239-5a27861ab854"}, {"type": "NATIONAL_ID", "value": "5032271632"}, {"type": "crvs", "event": "death", "value": "69cc580c-378e-4faf-b5c3-3867aa33c99d"}, {"type": "NATIONAL_ID", "value": "5032271632"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DIYDF0O"}]	deceased	2025-06-11 13:25:42.43632	2025-06-11 15:18:18.392	2025-06-08
1a7684f1-a2bf-4bd1-afc7-1ddcdb922e48	David Father	Lee	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "42a33433-605a-4c8d-b080-bae69173f89b"}, {"type": "NATIONAL_ID", "value": "5505434811"}]	active	2025-06-12 08:12:45.590034	2025-06-12 08:12:45.590034	\N
dd34a4b1-2d1f-4e8b-bde4-ac1bd8b6d9f5	Jane	Bride	female	1992-02-02	Unknown	[{"type": "crvs", "event": "birth", "value": "e3a608b8-1bd6-40a5-a706-459f592fe490"}, {"type": "NATIONAL_ID", "value": "1085903555"}]	active	2025-06-12 08:52:39.349319	2025-06-12 08:52:39.349319	\N
d900966d-0646-4439-a658-a03055a2f96b	Quick Test	Demo	male	2025-06-06	Unknown, FAR	[{"type": "NATIONAL_ID", "value": "2025BWWQGSZ"}, {"type": "crvs", "event": "birth", "value": "72361f81-735e-4995-94de-6c5431a88b87"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BWWQGSZ"}]	active	2025-06-12 09:06:52.904355	2025-06-12 09:06:52.904355	\N
ec69972a-e631-4ae8-8337-6354237575ad	John	Groom	male	1990-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "cada2820-c439-44e6-a893-3d1ac8e5c994"}, {"type": "NATIONAL_ID", "value": "1751360632"}, {"type": "crvs", "event": "death", "value": "0288a03a-fb26-455d-89bc-6fa0c533dc87"}, {"type": "NATIONAL_ID", "value": "1751360632"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DNXD5P3"}]	deceased	2025-06-12 08:52:38.039711	2025-06-16 12:44:06.472	2025-06-08
928393b4-bea8-474b-aeea-f3589e1e5bbc	David Mother	LEE	female	1970-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "11714bb9-8b82-456a-a90f-a54f8d6e86b1"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-1"}]	review	2025-06-17 15:09:45.657158	2025-06-17 15:09:45.657158	\N
dd3b2bdf-640c-469e-ace7-6c77d55a40e2	David Child	LEE	male	2025-06-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BKIVTZR"}, {"type": "crvs", "event": "birth", "value": "5e72beca-e7e2-44ea-8b01-5e0b45e0fd1d"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BKIVTZR"}]	active	2025-06-17 15:09:49.543295	2025-06-17 15:09:49.543295	\N
15648b23-2943-4ad5-9eb6-1a64d42c52a5	Test Test	Child1 Mother	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "e84d7064-6933-450d-9c0a-9adcc2d901f7"}, {"type": "NATIONAL_ID", "value": "1111111111"}]	review	2025-06-23 15:32:49.490745	2025-06-23 15:32:49.490745	\N
3e08b8ef-a8c0-492d-9bfa-7841cf539131	Test Test	Child1	male	2025-06-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025B2WWCMY"}, {"type": "crvs", "event": "birth", "value": "82a5b1a8-271e-4a07-a29e-58c0a2098dfe"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025B2WWCMY"}]	active	2025-06-23 15:32:53.016262	2025-06-23 15:32:53.016262	\N
33482d70-1bdd-45fe-b205-f5f63c9cd354	Trial Mother	A	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "944355ac-ae61-48e7-94c7-862a79102a5f"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999"}]	review	2025-06-25 15:01:23.699388	2025-06-25 15:01:23.699388	\N
ebaaa1fb-f9cc-4e26-9b04-4c3ff49c1ed3	Trial Child	A	male	2025-06-01	Health Institution, Bombwe Health Post	[{"type": "NATIONAL_ID", "value": "2025BNYNFIS"}, {"type": "crvs", "event": "birth", "value": "3f562fb1-2b34-417f-94b3-aea24ed8cac0"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BNYNFIS"}]	active	2025-06-25 15:01:27.544716	2025-06-25 15:01:27.544716	\N
7fd96655-c186-49cf-abad-c8c98954ea61	Trial Father	A	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "9029eb48-1e9f-4dc9-9a19-02b686188fd7"}, {"type": "NATIONAL_ID", "value": "6440569416"}, {"type": "crvs", "event": "death", "value": "23f70c81-a6c7-418b-b28d-ebf7092fe81e"}, {"type": "NATIONAL_ID", "value": "6440569416"}, {"type": "DEATH_REGISTRATION_NUMBER", "value": "2025DHE9BHJ"}]	deceased	2025-06-25 14:52:02.422234	2025-06-25 15:17:45.384	2025-06-02
c60db9a2-5e82-4762-9df1-5bd27adfe8bf	Demo Father	B	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "875a9f23-d337-40d3-94ee-94a7e008ebb0"}, {"type": "NATIONAL_ID", "value": "3941409923"}]	active	2025-06-25 15:40:28.8414	2025-06-25 15:40:28.8414	\N
f6363e55-7d9b-46e2-b08d-af3ac2c51296	Demo Father	C	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "0866ed46-6e26-493b-8cfd-c8bacf58e65f"}, {"type": "NATIONAL_ID", "value": "8335480395"}]	active	2025-06-27 11:15:56.89639	2025-06-27 11:15:56.89639	\N
e20dece4-dc58-4b9d-96f9-9cdd1d29589a	Demo Father	D	male	1968-01-01	Town, FAR	[{"type": "crvs", "event": "birth", "value": "e10d3f04-a4a3-4de9-8e76-5cfbf99b8388"}, {"type": "NATIONAL_ID", "value": "4368972177"}]	active	2025-06-27 11:16:03.45108	2025-06-27 11:16:03.45108	\N
58793d93-f855-4e24-a266-d4b299697da7	Trial Mother	00A	female	1975-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "416b02c6-97ee-4531-a917-b7cbf6ef09a7"}, {"type": "SOCIAL_SECURITY_CARD", "value": "999999-1-700101-AG-A"}]	review	2025-06-27 11:55:52.722107	2025-06-27 11:55:52.722107	\N
819e7f68-e13d-4653-8623-2ff0d458d665	Trial Daughter	00A	female	2025-05-16	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BDBQNUO"}, {"type": "crvs", "event": "birth", "value": "be42c002-872e-473d-8787-ec6e2ef162e8"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BDBQNUO"}]	active	2025-06-27 11:55:56.446234	2025-06-27 11:55:56.446234	\N
a6468ea7-218b-42dc-869b-23c0e074e087	Demo	Mother C	female	1970-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "31406142-9463-4ea5-a9fa-11917933beff"}, {"type": "NATIONAL_ID", "value": "2000000001"}]	review	2025-06-27 13:34:45.904979	2025-06-27 13:34:45.904979	\N
7fcece71-1d59-49d6-b263-30aefb340e23	Demo Daughter New	C	female	2025-06-15	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BITDOD4"}, {"type": "crvs", "event": "birth", "value": "3ac677f0-d867-4be2-bd69-b6aab6f39eaa"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BITDOD4"}]	active	2025-06-27 13:34:49.893331	2025-06-27 13:34:49.893331	\N
469773b9-7c6e-4901-aa92-f5d1146acc08	Demo	Mother D	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "9e24b5c8-e251-4265-a7d3-b654cc84ac01"}, {"type": "NATIONAL_ID", "value": "1234567890"}]	review	2025-06-27 19:43:54.853108	2025-06-27 19:43:54.853108	\N
50989c77-8345-4763-a12c-21f43d9e525f	Trial Child	D	male	2025-01-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BUIWAKY"}, {"type": "crvs", "event": "birth", "value": "06d15446-586d-43e4-8878-64ed07178a29"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BUIWAKY"}]	active	2025-06-27 19:43:59.482499	2025-06-27 19:43:59.482499	\N
b061b4d1-30fd-4390-b663-56caa6737441	Test	Mother	female	1985-01-01	Unknown	[{"type": "crvs", "event": "birth", "value": "97c2bdb9-3f15-40e2-82cb-8da0fa9fcff8"}, {"type": "NATIONAL_ID", "value": "1000000001"}]	review	2025-07-18 14:47:16.46567	2025-07-18 14:47:16.46567	\N
66144acd-bfc0-4501-a58d-046a2e6e0c53	Test	Daughter Name	female	2025-07-01	Town, FAR	[{"type": "NATIONAL_ID", "value": "2025BRBDMBA"}, {"type": "crvs", "event": "birth", "value": "6f9e8fbe-dcf5-4c4d-bf33-7028d41b6826"}, {"type": "BIRTH_REGISTRATION_NUMBER", "value": "2025BRBDMBA"}]	active	2025-07-18 14:47:17.745762	2025-07-18 14:47:17.745762	\N
\.


--
-- Data for Name: person_id_mapping; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.person_id_mapping (person_id, external_person_id, source, linked_at) FROM stdin;
\.


--
-- Data for Name: person_name_history; Type: TABLE DATA; Schema: public; Owner: registry_user
--

COPY public.person_name_history (id, person_id, given_name, family_name, change_reason, valid_from, valid_to, created_at) FROM stdin;
\.


--
-- Name: event_participant event_participant_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.event_participant
    ADD CONSTRAINT event_participant_pkey PRIMARY KEY (id);


--
-- Name: event event_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.event
    ADD CONSTRAINT event_pkey PRIMARY KEY (id);


--
-- Name: family_link family_link_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.family_link
    ADD CONSTRAINT family_link_pkey PRIMARY KEY (id);


--
-- Name: person_id_mapping person_id_mapping_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.person_id_mapping
    ADD CONSTRAINT person_id_mapping_pkey PRIMARY KEY (person_id, external_person_id);


--
-- Name: person_name_history person_name_history_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.person_name_history
    ADD CONSTRAINT person_name_history_pkey PRIMARY KEY (id);


--
-- Name: person person_pkey; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.person
    ADD CONSTRAINT person_pkey PRIMARY KEY (id);


--
-- Name: family_link unique_family_link; Type: CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.family_link
    ADD CONSTRAINT unique_family_link UNIQUE (person_id, related_person_id, relationship_type, source_event_id);


--
-- Name: idx_event_type; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_event_type ON public.event USING btree (event_type);


--
-- Name: idx_family_link_event; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_family_link_event ON public.family_link USING btree (source_event_id);


--
-- Name: idx_family_link_person_id; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_family_link_person_id ON public.family_link USING btree (person_id);


--
-- Name: idx_family_link_related_person_id; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_family_link_related_person_id ON public.family_link USING btree (related_person_id);


--
-- Name: idx_full_name; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_full_name ON public.person USING btree (full_name);


--
-- Name: idx_identifiers_gin; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_identifiers_gin ON public.person USING gin (identifiers);


--
-- Name: idx_name_history_full_name; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_name_history_full_name ON public.person_name_history USING btree (full_name);


--
-- Name: idx_name_history_valid_from; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_name_history_valid_from ON public.person_name_history USING btree (valid_from);


--
-- Name: idx_person_event; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_person_event ON public.event_participant USING btree (person_id, event_id);


--
-- Name: idx_role; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE INDEX idx_role ON public.event_participant USING btree (role);


--
-- Name: unique_active_participant; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE UNIQUE INDEX unique_active_participant ON public.event_participant USING btree (event_id, crvs_person_id) WHERE (status = 'active'::text);


--
-- Name: unique_crvs_event_uuid; Type: INDEX; Schema: public; Owner: registry_user
--

CREATE UNIQUE INDEX unique_crvs_event_uuid ON public.event USING btree (crvs_event_uuid);


--
-- Name: event_participant trg_create_family_link_from_event; Type: TRIGGER; Schema: public; Owner: registry_user
--

CREATE TRIGGER trg_create_family_link_from_event AFTER INSERT OR UPDATE ON public.event_participant FOR EACH ROW EXECUTE FUNCTION public.create_family_link_from_event();


--
-- Name: family_link trg_create_reverse_family_link; Type: TRIGGER; Schema: public; Owner: registry_user
--

CREATE TRIGGER trg_create_reverse_family_link AFTER INSERT ON public.family_link FOR EACH ROW EXECUTE FUNCTION public.create_reverse_family_link();


--
-- Name: event_participant event_participant_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.event_participant
    ADD CONSTRAINT event_participant_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.event(id) ON DELETE CASCADE;


--
-- Name: event_participant event_participant_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.event_participant
    ADD CONSTRAINT event_participant_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON DELETE CASCADE;


--
-- Name: family_link family_link_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.family_link
    ADD CONSTRAINT family_link_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id) ON DELETE CASCADE;


--
-- Name: family_link family_link_related_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.family_link
    ADD CONSTRAINT family_link_related_person_id_fkey FOREIGN KEY (related_person_id) REFERENCES public.person(id) ON DELETE CASCADE;


--
-- Name: family_link family_link_source_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.family_link
    ADD CONSTRAINT family_link_source_event_id_fkey FOREIGN KEY (source_event_id) REFERENCES public.event(id) ON DELETE SET NULL;


--
-- Name: person_name_history person_name_history_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: registry_user
--

ALTER TABLE ONLY public.person_name_history
    ADD CONSTRAINT person_name_history_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.person(id);


--
-- PostgreSQL database dump complete
--

