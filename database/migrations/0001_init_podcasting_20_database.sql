-- 0001 migration

/*

PODCASTING 2.0 DATABASE SCHEMA

- The `id` column is a SERIAL column that is used as the primary key for every table.

- The `id_text` column is only intended for tables where the data is available as urls.
  For example, https://podverse.fm/podcast/abc123def456, the `id_text` column would be `abc123def456`.

- The `slug` column is not required, but functions as an alternative for `id_text`.
  For example, https://podverse.fm/podcast/podcasting-20 would have a `slug` column with the value `podcasting-20`.

- The `podcast_index_id` ensures that our database only contains feed data that is available in the Podcast Index API.

*/

----------** GLOBAL REFERENCE TABLES **----------
-- These tables are referenced across many tables, and must be created first.

--** CATEGORY

-- Allowed category values align with the standard categories and subcategories
-- supported by Apple iTunes through the <itunes:category> tag.
-- 
CREATE TABLE category (
    id SERIAL PRIMARY KEY,
    node_text varchar_normal NOT NULL, -- <itunes:category>
    display_name varchar_normal NOT NULL, -- our own display name for the category
    slug varchar_normal NOT NULL -- our own slug for the category
);

--** MEDIUM VALUE

-- <podcast:medium>
CREATE TABLE medium (
    id SERIAL PRIMARY KEY,
    value TEXT UNIQUE CHECK (VALUE IN (
        'publisher',
        'podcast', 'music', 'video', 'film', 'audiobook', 'newsletter', 'blog', 'publisher', 'course',
        'mixed', 'podcastL', 'musicL', 'videoL', 'filmL', 'audiobookL', 'newsletterL', 'blogL', 'publisherL', 'courseL'
    ))
);

INSERT INTO medium (value) VALUES
    ('publisher'),
    ('podcast'), ('music'), ('video'), ('film'), ('audiobook'), ('newsletter'), ('blog'), ('course'),
    ('mixed'), ('podcastL'), ('musicL'), ('videoL'), ('filmL'), ('audiobookL'), ('newsletterL'), ('blogL'), ('publisherL'), ('courseL')
;

----------** TABLES **----------

--** FEED > FLAG STATUS

-- used internally for identifying and handling spam and other special flag statuses.
CREATE TABLE feed_flag_status (
    id SERIAL PRIMARY KEY,
    status TEXT UNIQUE CHECK (status IN ('none', 'spam', 'takedown', 'other', 'always-allow')),
    created_at server_time_with_default,
    updated_at server_time_with_default
);

CREATE TRIGGER set_updated_at_feed_flag_status
BEFORE UPDATE ON feed_flag_status
FOR EACH ROW
EXECUTE FUNCTION set_updated_at_field();

INSERT INTO feed_flag_status (status) VALUES ('none'), ('spam'), ('takedown'), ('other'), ('always-allow');

--** FEED

-- The top-level table for storing feed data, and internal parsing data.
CREATE TABLE feed (
    id SERIAL PRIMARY KEY,
    url varchar_url UNIQUE NOT NULL,

    -- feed flag
    feed_flag_status_id INTEGER NOT NULL REFERENCES feed_flag_status(id),

    -- internal

    -- Used to prevent another thread from parsing the same feed.
    -- Set to current time at beginning of parsing, and NULL at end of parsing. 
    -- This is to prevent multiple threads from parsing the same feed.
    -- If is_parsing is over X minutes old, assume last parsing failed and proceed to parse.
    is_parsing server_time,

    -- 0 will only be parsed when PI API reports an update.
    -- higher parsing_priority will be parsed more frequently on a schedule.
    parsing_priority INTEGER DEFAULT 0 CHECK (parsing_priority BETWEEN 0 AND 5),

    -- the hash of the last parsed feed file.
    -- used for comparison to determine if full re-parsing is needed.
    last_parsed_file_hash varchar_md5,

    -- the run-time environment container id
    container_id VARCHAR(12),

    created_at server_time_with_default,
    updated_at server_time_with_default
);

CREATE INDEX idx_feed_feed_flag_status_id ON feed(feed_flag_status_id);

CREATE TRIGGER set_updated_at_feed
BEFORE UPDATE ON feed
FOR EACH ROW
EXECUTE FUNCTION set_updated_at_field();

CREATE TABLE feed_log (
    id SERIAL PRIMARY KEY,
    feed_id INTEGER NOT NULL UNIQUE REFERENCES feed(id) ON DELETE CASCADE,
    last_http_status INTEGER,
    last_good_http_status_time server_time,
    last_finished_parse_time server_time,
    parse_errors INTEGER DEFAULT 0
);

CREATE INDEX idx_feed_log_feed_id ON feed_log(feed_id);

--** CHANNEL

-- <channel>
CREATE TABLE channel (
    id SERIAL PRIMARY KEY,
    id_text short_id_v2 UNIQUE NOT NULL,
    slug varchar_slug,
    feed_id INTEGER NOT NULL UNIQUE REFERENCES feed(id) ON DELETE CASCADE,
    podcast_index_id INTEGER UNIQUE NOT NULL,
    podcast_guid UUID UNIQUE, -- <podcast:guid>
    title varchar_normal,
    sortable_title varchar_short, -- all lowercase, ignores articles at beginning of title
    medium_id INTEGER REFERENCES medium(id),

    -- channels that have a PI value tag require special handling to request value data
    -- from the Podcast Index API.
    has_podcast_index_value BOOLEAN DEFAULT FALSE,

    -- this column is used for optimization purposes to determine if all of the items
    -- for a channel need to have their value time split remote items parsed.
    has_value_time_splits BOOLEAN DEFAULT FALSE,

    -- hidden items are no longer available in the rss feed, but are still in the database.
    hidden BOOLEAN DEFAULT FALSE,
    -- markedForDeletion items are no longer available in the rss feed, and may be able to be deleted.
    marked_for_deletion BOOLEAN DEFAULT FALSE
);

CREATE UNIQUE INDEX channel_podcast_guid_unique ON channel(podcast_guid) WHERE podcast_guid IS NOT NULL;
CREATE UNIQUE INDEX channel_slug ON channel(slug) WHERE slug IS NOT NULL;
CREATE INDEX idx_channel_feed_id ON channel(feed_id);
CREATE INDEX idx_channel_medium_id ON channel(medium_id);

--** CHANNEL > ABOUT > ITUNES TYPE

-- <channel> -> <itunes:type>
CREATE TABLE channel_itunes_type (
    id SERIAL PRIMARY KEY,
    itunes_type TEXT UNIQUE CHECK (itunes_type IN ('episodic', 'serial'))
);

INSERT INTO channel_itunes_type (itunes_type) VALUES ('episodic'), ('serial');

--** CHANNEL > ABOUT

-- various <channel> child data from multiple tags
CREATE TABLE channel_about (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE,
    author varchar_normal, -- <itunes:author> and <author>
    episode_count INTEGER, -- aggregated count for convenience
    explicit BOOLEAN, -- <itunes:explicit>
    itunes_type_id INTEGER REFERENCES channel_itunes_type(id),
    language varchar_short, -- <language>
    last_pub_date server_time_with_default, -- <pubDate>
    website_link_url varchar_url -- <link>
);

CREATE INDEX idx_channel_about_channel_id ON channel_about(channel_id);
CREATE INDEX idx_channel_about_itunes_type_id ON channel_about(itunes_type_id);

--** CHANNEL > CATEGORY

CREATE TABLE channel_category (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    parent_id INTEGER REFERENCES channel_category(id) ON DELETE CASCADE
);

CREATE INDEX idx_channel_category_channel_id ON channel_category(channel_id);
CREATE INDEX idx_channel_category_parent_id ON channel_category(parent_id);

--** CHANNEL > CHAT

-- <channel> -> <podcast:chat>
CREATE TABLE channel_chat (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE,
    server varchar_fqdn NOT NULL,
    protocol varchar_short NOT NULL,
    account_id varchar_normal,
    space varchar_normal
);

CREATE INDEX idx_channel_chat_channel_id ON channel_chat(channel_id);

--** CHANNEL > DESCRIPTION

-- <channel> -> <description> AND possibly other tags that contain a description
CREATE TABLE channel_description (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE,
    value varchar_long NOT NULL
);

CREATE INDEX idx_channel_description_channel_id ON channel_description(channel_id);

--** CHANNEL > FUNDING

-- <channel> -> <podcast:funding>
CREATE TABLE channel_funding (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    title varchar_normal
);

CREATE INDEX idx_channel_funding_channel_id ON channel_funding(channel_id);

--** CHANNEL > IMAGE

-- <channel> -> <podcast:image> AND all other image tags in the rss feed
CREATE TABLE channel_image (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    image_width_size INTEGER, -- <podcast:image> must have a width specified, but older image tags will not, so allow null.

    -- If true, then the image is hosted by us in a service like S3.
    -- When is_resized images are deleted, the corresponding image in S3
    -- should also be deleted.
    is_resized BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_channel_image_channel_id ON channel_image(channel_id);

--** CHANNEL > INTERNAL SETTINGS

CREATE TABLE channel_internal_settings (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    -- needed to approve which web domains can override the player with query params.
    -- this prevents malicious parties from misrepresenting the podcast contents on another website.
    embed_approved_media_url_paths TEXT
);

CREATE INDEX idx_channel_internal_settings_channel_id ON channel_internal_settings(channel_id);

--** CHANNEL > LICENSE

-- <channel> -> <podcast:license>
CREATE TABLE channel_license (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE,
    identifier varchar_normal NOT NULL,
    url varchar_url
);

CREATE INDEX idx_channel_license_channel_id ON channel_license(channel_id);

--** CHANNEL > LOCATION

-- <channel> -> <podcast:location>
CREATE TABLE channel_location (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE,
    geo varchar_normal,
    osm varchar_normal,
    CHECK (geo IS NOT NULL OR osm IS NOT NULL),
    name varchar_normal
);

CREATE INDEX idx_channel_location_channel_id ON channel_location(channel_id);

--** CHANNEL > PERSON

-- <channel> -> <podcast:person>
CREATE TABLE channel_person (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    name varchar_normal NOT NULL,
    role varchar_normal,
    person_group varchar_normal DEFAULT 'cast', -- group is a reserved keyword in sql
    img varchar_url,
    href varchar_url
);

CREATE INDEX idx_channel_person_channel_id ON channel_person(channel_id);

--** CHANNEL > PODROLL

-- <channel> -> <podcast:podroll>
CREATE TABLE channel_podroll (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE
);

CREATE INDEX idx_channel_podroll_channel_id ON channel_podroll(channel_id);

--** CHANNEL > PODROLL > REMOTE ITEM

-- <channel> -> <podcast:podroll> --> <podcast:remoteItem>
CREATE TABLE channel_podroll_remote_item (
    id SERIAL PRIMARY KEY,
    channel_podroll_id INTEGER NOT NULL REFERENCES channel_podroll(id) ON DELETE CASCADE,
    feed_guid UUID NOT NULL,
    feed_url varchar_url,
    item_guid varchar_uri,
    title varchar_normal,
    medium_id INTEGER REFERENCES medium(id)
);

CREATE INDEX idx_channel_podroll_remote_item_channel_podroll_id ON channel_podroll_remote_item(channel_podroll_id);
CREATE INDEX idx_channel_podroll_remote_item_medium_id ON channel_podroll_remote_item(medium_id);
CREATE INDEX idx_channel_podroll_remote_item_feed_guid ON channel_podroll_remote_item(feed_guid);
CREATE INDEX idx_channel_podroll_remote_item_feed_url ON channel_podroll_remote_item(feed_url);
CREATE INDEX idx_channel_podroll_remote_item_item_guid ON channel_podroll_remote_item(item_guid);

--** CHANNEL > PUBLISHER

-- <channel> -> <podcast:publisher>
CREATE TABLE channel_publisher (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL UNIQUE REFERENCES channel(id) ON DELETE CASCADE
);

CREATE INDEX idx_channel_publisher_channel_id ON channel_publisher(channel_id);

--** CHANNEL > PUBLISHER > REMOTE ITEM

-- <channel> -> <podcast:publisher> -> <podcast:remoteItem>
CREATE TABLE channel_publisher_remote_item (
    id SERIAL PRIMARY KEY,
    channel_publisher_id INTEGER NOT NULL UNIQUE REFERENCES channel_publisher(id) ON DELETE CASCADE,
    feed_guid UUID NOT NULL,
    feed_url varchar_url,
    item_guid varchar_uri,
    title varchar_normal,
    medium_id INTEGER REFERENCES medium(id)
);

CREATE INDEX idx_channel_publisher_remote_item_channel_publisher_id ON channel_publisher_remote_item(channel_publisher_id);
CREATE INDEX idx_channel_publisher_remote_item_medium_id ON channel_publisher_remote_item(medium_id);
CREATE INDEX idx_channel_publisher_remote_item_feed_guid ON channel_publisher_remote_item(feed_guid);
CREATE INDEX idx_channel_publisher_remote_item_feed_url ON channel_publisher_remote_item(feed_url);
CREATE INDEX idx_channel_publisher_remote_item_item_guid ON channel_publisher_remote_item(item_guid);

--** CHANNEL > REMOTE ITEM

-- Remote items at the channel level are only used when the <podcast:medium> for the channel
-- is set to 'mixed' or another list medium like 'podcastL'.

-- <channel> -> <podcast:remoteItem>
CREATE TABLE channel_remote_item (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    feed_guid UUID NOT NULL,
    feed_url varchar_url,
    item_guid varchar_uri,
    title varchar_normal,
    medium_id INTEGER REFERENCES medium(id)
);

CREATE INDEX idx_channel_remote_item_channel_id ON channel_remote_item(channel_id);
CREATE INDEX idx_channel_remote_item_medium_id ON channel_remote_item(medium_id);
CREATE INDEX idx_channel_remote_item_feed_guid ON channel_remote_item(feed_guid);
CREATE INDEX idx_channel_remote_item_feed_url ON channel_remote_item(feed_url);
CREATE INDEX idx_channel_remote_item_item_guid ON channel_remote_item(item_guid);

--** CHANNEL > SEASON

-- channels with seasons need to be rendered in client apps differently.
-- you can only determine if a channel is in a "season" format is by finding
-- the <itunes:season> tag in an item in that channel.

-- NOTE: A channel season does not exist in the Podcasting 2.0 spec,
-- but it is useful for organizing seasons at the channel level,
-- and could be in the P2.0 spec someday.

CREATE TABLE channel_season (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    number INTEGER NOT NULL,
    UNIQUE (channel_id, number),
    name varchar_normal
);

CREATE INDEX idx_channel_season_channel_id ON channel_season(channel_id);

--** CHANNEL > SOCIAL INTERACT

-- <channel> -> <podcast:socialInteract>
CREATE TABLE channel_social_interact (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    protocol varchar_short NOT NULL,
    uri varchar_uri NOT NULL,
    account_id varchar_normal,
    account_url varchar_url,
    priority INTEGER
);

CREATE INDEX idx_channel_social_interact_channel_id ON channel_social_interact(channel_id);

--** CHANNEL > TRAILER

-- <channel> -> <podcast:trailer>
CREATE TABLE channel_trailer (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    title varchar_normal,
    pubdate TIMESTAMPTZ NOT NULL,
    length INTEGER,
    type varchar_short,
    channel_season_id INTEGER REFERENCES channel_season(id),
    UNIQUE (channel_id, url)
);

CREATE INDEX idx_channel_trailer_channel_id ON channel_trailer(channel_id);
CREATE INDEX idx_channel_trailer_channel_season_id ON channel_trailer(channel_season_id);

--** CHANNEL > TXT

-- <channel> -> <podcast:txt>
CREATE TABLE channel_txt (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    purpose varchar_normal,
    value varchar_long NOT NULL
);

CREATE INDEX idx_channel_txt_channel_id ON channel_txt(channel_id);

--** CHANNEL > VALUE

-- <channel> -> <podcast:value>
CREATE TABLE channel_value (
    id SERIAL PRIMARY KEY,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    method varchar_short NOT NULL,
    suggested FLOAT
);

CREATE INDEX idx_channel_value_channel_id ON channel_value(channel_id);

--** CHANNEL > VALUE > RECEIPIENT

-- <channel> -> <podcast:value> -> <podcast:valueRecipient>
CREATE TABLE channel_value_recipient (
    id SERIAL PRIMARY KEY,
    channel_value_id INTEGER NOT NULL REFERENCES channel_value(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    address varchar_long NOT NULL,
    split FLOAT NOT NULL,
    name varchar_normal,
    custom_key varchar_long,
    custom_value varchar_long,
    fee BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_channel_value_recipient_channel_value_id ON channel_value_recipient(channel_value_id);

--** ITEM

-- Technically the item table could be named channel_item, but it seems easier to understand as item.

-- <channel> -> <item>
CREATE TABLE item (
    id SERIAL PRIMARY KEY,
    id_text short_id_v2 UNIQUE NOT NULL,
    slug varchar_slug,
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    guid varchar_uri, -- <guid>
    guid_enclosure_url varchar_url NOT NULL, -- enclosure url
    pubdate TIMESTAMPTZ, -- <pubDate>
    title varchar_normal, -- <title>

    -- hidden items are no longer available in the rss feed, but are still in the database.
    hidden BOOLEAN DEFAULT FALSE,
    -- markedForDeletion items are no longer available in the rss feed, and may be able to be deleted.
    marked_for_deletion BOOLEAN DEFAULT FALSE
);

CREATE UNIQUE INDEX item_slug ON item(slug) WHERE slug IS NOT NULL;
CREATE INDEX idx_item_channel_id ON item(channel_id);

--** ITEM > ABOUT > ITUNES TYPE

-- <item> -> <itunes:episodeType>
CREATE TABLE item_itunes_episode_type (
    id SERIAL PRIMARY KEY,
    itunes_episode_type TEXT UNIQUE CHECK (itunes_episode_type IN ('full', 'trailer', 'bonus'))
);

INSERT INTO item_itunes_episode_type (itunes_episode_type) VALUES ('full'), ('trailer'), ('bonus');

--** ITEM > ABOUT

CREATE TABLE item_about (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    duration media_player_time, -- <itunes:duration>
    explicit BOOLEAN, -- <itunes:explicit>
    website_link_url varchar_url, -- <link>
    item_itunes_episode_type_id INTEGER REFERENCES item_itunes_episode_type(id) -- <itunes:episodeType>
);

CREATE INDEX idx_item_about_item_id ON item_about(item_id);
CREATE INDEX idx_item_about_item_itunes_episode_type_id ON item_about(item_itunes_episode_type_id);

--** ITEM > CHAPTERS

-- <item> -> <podcast:chapters>
CREATE TABLE item_chapters_feed (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    type varchar_short NOT NULL
);

CREATE INDEX idx_item_chapters_feed_item_id ON item_chapters_feed(item_id);

--** ITEM > CHAPTERS > LOG

-- <item> -> <podcast:chapters> -> parsing logs

CREATE TABLE item_chapters_feed_log (
    id SERIAL PRIMARY KEY,
    item_chapters_feed_id INTEGER NOT NULL UNIQUE REFERENCES item_chapters_feed(id) ON DELETE CASCADE,
    last_http_status INTEGER,
    last_good_http_status_time server_time,
    last_finished_parse_time server_time,
    parse_errors INTEGER DEFAULT 0
);

CREATE INDEX idx_item_chapters_feed_log_item_chapters_feed_id ON item_chapters_feed_log(item_chapters_feed_id);

--** ITEM > CHAPTERS > CHAPTER

-- -- <item> -> <podcast:chapters> -> chapter items correspond with jsonChapters.md example file
CREATE TABLE item_chapter (
    id SERIAL PRIMARY KEY,
    id_text short_id_v2 UNIQUE NOT NULL,
    item_chapters_feed_id INTEGER NOT NULL REFERENCES item_chapters_feed(id) ON DELETE CASCADE,
    start_time media_player_time NOT NULL,
    end_time media_player_time,
    title varchar_normal,
    img varchar_url,
    web_url varchar_url,
    table_of_contents BOOLEAN DEFAULT TRUE
);

CREATE INDEX idx_item_chapter_item_chapters_feed_id ON item_chapter(item_chapters_feed_id);

--** ITEM > CHAPTER > LOCATION

-- <item> -> <podcast:chapters> -> chapter items correspond with jsonChapters.md example file
CREATE TABLE item_chapter_location (
    id SERIAL PRIMARY KEY,
    item_chapter_id INTEGER NOT NULL UNIQUE REFERENCES item_chapter(id) ON DELETE CASCADE,
    geo varchar_normal,
    osm varchar_normal,
    CHECK (geo IS NOT NULL OR osm IS NOT NULL),
    name varchar_normal
);

CREATE INDEX idx_item_chapter_location_item_chapter_id ON item_chapter_location(item_chapter_id);

--** ITEM > CHAT

-- <item> -> <podcast:chat>
CREATE TABLE item_chat (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    server varchar_fqdn NOT NULL,
    protocol varchar_short NOT NULL,
    account_id varchar_normal,
    space varchar_normal
);

CREATE INDEX idx_item_chat_item_id ON item_chat(item_id);

--** ITEM > CONTENT LINK

-- <item> -> <podcast:contentLink>
CREATE TABLE item_content_link (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    href varchar_url NOT NULL,
    title varchar_normal
);

CREATE INDEX idx_item_content_link_item_id ON item_content_link(item_id);

--** ITEM > DESCRIPTION

-- <item> -> <description> AND possibly other tags that contain a description
CREATE TABLE item_description (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    value varchar_long NOT NULL
);

CREATE INDEX idx_item_description_item_id ON item_description(item_id);

--** ITEM > ENCLOSURE (AKA ALTERNATE ENCLOSURE)

-- NOTE: the older <enclosure> tag style is integrated into the item_enclosure table.

-- <item> -> <podcast:alternateEnclosure> AND <item> -> <enclosure>
CREATE TABLE item_enclosure (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    length INTEGER,
    bitrate INTEGER,
    height INTEGER,
    language varchar_short,
    title varchar_short,
    rel varchar_short,
    codecs varchar_short,
    item_enclosure_default BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_item_enclosure_item_id ON item_enclosure(item_id);

-- <item> -> <podcast:alternateEnclosure> -> <podcast:source>
CREATE TABLE item_enclosure_source (
    id SERIAL PRIMARY KEY,
    item_enclosure_id INTEGER NOT NULL REFERENCES item_enclosure(id) ON DELETE CASCADE,
    uri varchar_uri NOT NULL,
    content_type varchar_short
);

CREATE INDEX idx_item_enclosure_source_item_id ON item_enclosure_source(item_enclosure_id);

-- <item> -> <podcast:alternateEnclosure> -> <podcast:integrity>
CREATE TABLE item_enclosure_integrity (
    id SERIAL PRIMARY KEY,
    item_enclosure_id INTEGER NOT NULL UNIQUE REFERENCES item_enclosure_source(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('sri', 'pgp-signature')),
    value varchar_long NOT NULL
);

CREATE INDEX idx_item_enclosure_integrity_item_enclosure_id ON item_enclosure_integrity(item_enclosure_id);

--** ITEM > FUNDING

-- <item> -> <podcast:funding>
CREATE TABLE item_funding (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    title varchar_normal
);

CREATE INDEX idx_item_funding_item_id ON item_funding(item_id);

--** ITEM > IMAGE

-- <item> -> <podcast:image> AND all other image tags in the rss feed
CREATE TABLE item_image (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    image_width_size INTEGER, -- <podcast:image> must have a width specified, but older image tags will not, so allow null.

    -- If true, then the image is hosted by us in a service like S3.
    -- When is_resized images are deleted, the corresponding image in S3
    -- should also be deleted.
    is_resized BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_item_image_item_id ON item_image(item_id);

--** ITEM > LICENSE

-- <item> -> <podcast:license>
CREATE TABLE item_license (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    identifier varchar_normal NOT NULL,
    url varchar_url
);

CREATE INDEX idx_item_license_item_id ON item_license(item_id);

--** ITEM > LOCATION

-- <item> -> <podcast:location>
CREATE TABLE item_location (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    geo varchar_normal,
    osm varchar_normal,
    CHECK (geo IS NOT NULL OR osm IS NOT NULL),
    name varchar_normal
);

CREATE INDEX idx_item_location_item_id ON item_location(item_id);

--** ITEM > PERSON

-- <item> -> <podcast:person>
CREATE TABLE item_person (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    name varchar_normal NOT NULL,
    role varchar_normal,
    person_group varchar_normal DEFAULT 'cast', -- group is a reserved keyword in sql
    img varchar_url,
    href varchar_url
);

CREATE INDEX idx_item_person_item_id ON item_person(item_id);

--** ITEM > SEASON

-- <item> -> <podcast:season>
CREATE TABLE item_season (
    id SERIAL PRIMARY KEY,
    channel_season_id INTEGER NOT NULL REFERENCES channel_season(id) ON DELETE CASCADE,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    title varchar_normal
);

CREATE INDEX idx_item_season_channel_season_id ON item_season(channel_season_id);
CREATE INDEX idx_item_season_item_id ON item_season(item_id);

--** ITEM > SEASON > EPISODE

-- <item> -> <podcast:season> -> <podcast:episode>
CREATE TABLE item_season_episode (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    display varchar_short,
    number FLOAT NOT NULL
);

CREATE INDEX idx_item_season_episode_item_id ON item_season_episode(item_id);

--** ITEM > SOCIAL INTERACT

-- <item> -> <podcast:socialInteract>
CREATE TABLE item_social_interact (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    protocol varchar_short NOT NULL,
    uri varchar_uri NOT NULL,
    account_id varchar_normal,
    account_url varchar_url,
    priority INTEGER
);

CREATE INDEX idx_item_social_interact_item_id ON item_social_interact(item_id);

--** ITEM > SOUNDBITE

-- <item> -> <podcast:soundbite>
CREATE TABLE item_soundbite (
    id SERIAL PRIMARY KEY,
    id_text short_id_v2 UNIQUE NOT NULL,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    start_time media_player_time NOT NULL,
    duration media_player_time NOT NULL,
    title varchar_normal
);

CREATE INDEX idx_item_soundbite_item_id ON item_soundbite(item_id);

--** ITEM > TRANSCRIPT

-- <item> -> <podcast:transcript>
CREATE TABLE item_transcript (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    url varchar_url NOT NULL,
    type varchar_short NOT NULL,
    language varchar_short,
    rel VARCHAR(50) CHECK (rel IS NULL OR rel = 'captions')
);

CREATE INDEX idx_item_transcript_item_id ON item_transcript(item_id);

--** ITEM > TXT

-- <item> -> <podcast:txt>
CREATE TABLE item_txt (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    purpose varchar_normal,
    value varchar_long NOT NULL
);

CREATE INDEX idx_item_txt_item_id ON item_txt(item_id);

--** ITEM > VALUE

-- <item> -> <podcast:value>
CREATE TABLE item_value (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    method varchar_short NOT NULL,
    suggested FLOAT
);

CREATE INDEX idx_item_value_item_id ON item_value(item_id);

--** ITEM > VALUE > RECEIPIENT

-- <item> -> <podcast:value> -> <podcast:valueRecipient>
CREATE TABLE item_value_recipient (
    id SERIAL PRIMARY KEY,
    item_value_id INTEGER NOT NULL REFERENCES item_value(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    address varchar_long NOT NULL,
    split FLOAT NOT NULL,
    name varchar_normal,
    custom_key varchar_long,
    custom_value varchar_long,
    fee BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_item_value_recipient_item_value_id ON item_value_recipient(item_value_id);

--** ITEM > VALUE > TIME SPLIT

-- <item> -> <podcast:value> -> <podcast:valueTimeSplit>
CREATE TABLE item_value_time_split (
    id SERIAL PRIMARY KEY,
    item_value_id INTEGER NOT NULL REFERENCES item_value(id) ON DELETE CASCADE,
    start_time media_player_time NOT NULL,
    duration media_player_time NOT NULL,
    remote_start_time media_player_time DEFAULT 0,
    remote_percentage media_player_time DEFAULT 100
);

CREATE INDEX idx_item_value_time_split_item_value_id ON item_value_time_split(item_value_id);

--** ITEM > VALUE > TIME SPLIT > REMOTE ITEM

-- <item> -> <podcast:value> -> <podcast:valueTimeSplit> -> <podcast:remoteItem>
CREATE TABLE item_value_time_split_remote_item (
    id SERIAL PRIMARY KEY,
    item_value_time_split_id INTEGER NOT NULL UNIQUE REFERENCES item_value_time_split(id) ON DELETE CASCADE,
    feed_guid UUID NOT NULL,
    feed_url varchar_url,
    item_guid varchar_uri,
    title varchar_normal
);

CREATE INDEX idx_item_value_time_split_remote_item_item_value_time_split_id ON item_value_time_split_remote_item(item_value_time_split_id);
CREATE INDEX idx_item_value_time_split_remote_item_feed_guid ON item_value_time_split_remote_item(feed_guid);
CREATE INDEX idx_item_value_time_split_remote_item_feed_url ON item_value_time_split_remote_item(feed_url);
CREATE INDEX idx_item_value_time_split_remote_item_item_guid ON item_value_time_split_remote_item(item_guid);

--** ITEM > VALUE > TIME SPLIT > VALUE RECIPEINT

-- <item> -> <podcast:value> -> <podcast:valueTimeSplit> -> <podcast:valueRecipient>
CREATE TABLE item_value_time_split_recipient (
    id SERIAL PRIMARY KEY,
    item_value_time_split_id INTEGER NOT NULL REFERENCES item_value_time_split(id) ON DELETE CASCADE,
    type varchar_short NOT NULL,
    address varchar_long NOT NULL,
    split FLOAT NOT NULL,
    name varchar_normal,
    custom_key varchar_long,
    custom_value varchar_long,
    fee BOOLEAN DEFAULT FALSE
);

CREATE INDEX idx_item_value_time_split_recipient_item_value_time_split_id ON item_value_time_split_recipient(item_value_time_split_id);

--** LIVE ITEM > STATUS

CREATE TABLE live_item_status (
    id SERIAL PRIMARY KEY,
    status TEXT UNIQUE CHECK (status IN ('pending', 'live', 'ended'))
);

INSERT INTO live_item_status (status) VALUES ('pending'), ('live'), ('ended');

--** LIVE ITEM

-- Technically the live_item table could be named channel_live_item,
-- but for consistency with the item table, it is called live_item.

-- <channel> -> <podcast:liveItem>
CREATE TABLE live_item (
    id SERIAL PRIMARY KEY,
    item_id INTEGER NOT NULL UNIQUE REFERENCES item(id) ON DELETE CASCADE,
    live_item_status_id INTEGER NOT NULL REFERENCES live_item_status(id),
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    chat_web_url varchar_url
);

CREATE INDEX idx_live_item_item_id ON live_item(item_id);
CREATE INDEX idx_live_item_live_item_status_id ON live_item(live_item_status_id);