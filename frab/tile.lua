local api, CHILDS, CONTENTS = ...

local json = require "json"
local helper = require "helper"
local anims = require(api.localized "anims")

local font, info_font
local white = resource.create_colored_texture(1,1,1)
local fallback_track_background = resource.create_colored_texture(.5,.5,.5,1)

local schedule = {}
local tracks = {}
local rooms = {}
local next_talks = {} -- List of all events up next from any defined room
local next_attendee_events = {}
local next_workshops = {} -- List of upcoming cfp events which are workshows
local current_room
local current_talk
local other_talks = {}
local day = 0
local show_language_tags = true
local any_venue_room_name = "ANY"
local emf_event_type_talk = "talk"
local just_started_mins = 5 -- Amount of time a event has "just started"

local M = {}

local function rgba(base, a)
    return base[1], base[2], base[3], a
end

-- Handle the "ANY" room mode where we need to get either the short name
-- for a defined room, or the venue room from the talk.
local function room_name_or_any(talk)
    -- Default for any room
    local name_short = talk.place
    -- If room is properly defined in infobeamer, use its short name
    if rooms[talk.place]
    then
        name_short = rooms[talk.place].name_short
    end
    return name_short
end

local function duration_text(duration)
    if duration and duration > 60 then
        local hours = (duration/60)
        if hours == math.floor(hours) then
            return string.format("%d hrs", hours)
        else
            return string.format("%.1f hrs", hours)
        end
    elseif duration > 0 then
        return string.format("%d mins", duration)
    end
end

function M.data_trigger(path, data)
    if path == "day" then
        day = tonumber(data)
        print('day set to', day)
    end
end

function M.updated_config_json(config)
    font = resource.load_font(api.localized(config.font.asset_name))
    info_font = resource.load_font(api.localized(config.info_font.asset_name))
    show_language_tags = config.show_language_tags
    just_started_mins = config.just_started_mins

    rooms = {}
    current_room = nil
    for idx, room in ipairs(config.rooms) do
        if room.serial == sys.get_env "SERIAL" then
            print("found my room")
            current_room = room
        end
        if room.name_short == "" then
            room.name_short = room.name
        end
        rooms[room.name] = room
    end

    if current_room then
        local info_lines = {}
        for line in string.gmatch(current_room.info.."\n", "([^\n]*)\n") do
            local split = string.find(line, ",")
            if not split then
                info_lines[#info_lines+1] = "splitter"
            else
                info_lines[#info_lines+1] = {
                    name = string.sub(line, 1, split-1),
                    value = string.sub(line, split+1),
                }
            end
        end
        current_room.info_lines = info_lines
    end

    tracks = {}
    for idx, track in ipairs(config.tracks) do
        local display_name = track.name
        if track.name_short then
            display_name = track.name_short
        end
        tracks[track.name] = {
            name = track.name,
            display_name = display_name,
            background = resource.create_colored_texture(unpack(track.color.rgba)),
            color = {track.color.r, track.color.g, track.color.b},
        }
    end
    pp(tracks)
end


function M.updated_schedule_json(new_schedule)
    print "new schedule"
    schedule = new_schedule
    for idx = #schedule, 1, -1 do
        local talk = schedule[idx]
        -- Hack to allow all venues on if there's a room called ANY
        if not rooms[talk.place] and not rooms[any_venue_room_name] then
            table.remove(schedule, idx)
        else
            if talk.lang ~= "" and show_language_tags then
                talk.title = talk.title .. " (" .. talk.lang .. ")"
            end

            talk.speaker_intro = (
                #talk.speakers == 0 and "" or
                (({
                    de = " mit ",
                })[talk.lang] or " with ") .. table.concat(talk.speakers, ", ")
            )

            talk.track = tracks[talk.track] or {
                name = talk.track,
                background = fallback_track_background,
            }
        end
    end
    pp(schedule)
end

local function wrap(str, font, size, max_w)
    local lines = {}
    local space_w = font:width(" ", size)

    local remaining = max_w
    local line = {}
    for non_space in str:gmatch("%S+") do
        local w = font:width(non_space, size)
        if remaining - w < 0 then
            lines[#lines+1] = table.concat(line, "")
            line = {}
            remaining = max_w
        end
        line[#line+1] = non_space
        line[#line+1] = " "
        remaining = remaining - w - space_w
    end
    if #line > 0 then
        lines[#lines+1] = table.concat(line, "")
    end
    return lines
end

local function check_next_talk()
    local now = api.clock.unix()
    print("Checking next talk")

    -- Search all next talks
    next_talks = {}
    next_attendee_events = {}
    next_workshops = {}

    local room_now = {} -- Event that appears as up next or now in each venue
    for idx = 1, #schedule do
        local talk = schedule[idx]

        -- Find now/next talk in each venue (room)
        -- These are expected to be the stages (and maybe workshops?)
        if current_room and (current_room.group == "*" or current_room.group == talk.group) then
            if not room_now[talk.place] and
                rooms[talk.place] and
                talk.start_unix > now - 25 * 60 then -- TODO check these timings...
                room_now[talk.place] = talk
            end
        end

        -- Just started?
        if now > talk.start_unix and
           now < talk.end_unix and
           talk.start_unix + just_started_mins * 60 > now
        then

            next_talks[#next_talks+1] = talk
            -- Have a separate list of events attendee submitted (not from the approved call for participation)
            if not talk.is_from_cfp
            then
                next_attendee_events[#next_attendee_events+1] = talk
            elseif string.find(talk.track.name, "workshops") then
                next_workshops[#next_workshops+1] = talk
            end
        end

        -- Starting soon
        -- Filter out events more than 23 hours away to hide confusing events which are the same hour but tomorrow!
        if talk.start_unix > now and (talk.start_unix < now + (60*60*23)) and #next_talks < 20 then

            next_talks[#next_talks+1] = talk
            -- Have a separate list of events attendee submitted (not from the approved call for participation)
            if not talk.is_from_cfp
            then
                next_attendee_events[#next_attendee_events+1] = talk
            elseif string.find(talk.track.name, "workshops") then
                next_workshops[#next_workshops+1] = talk
            end
        end
    end

    print("Found " .. #next_talks .. " next events")
    print("Found " .. #next_attendee_events .. " attendee events")

    if not current_room then
        return
    end

    -- Find current/next talk for my room
    current_talk = room_now[current_room.name]

    -- Prepare talks for other rooms
    -- These are ones that have just started in other venues or next up in them.
    other_talks = {}
    for idx = 1, #next_talks do
        local talk = next_talks[idx]
        -- Only include events in other defined rooms
        if ((not current_talk or talk.place ~= current_talk.place) and
            rooms[talk.place])
        then
            other_talks[#other_talks + 1] = talk
        end
    end

    local function sort_talks(a, b)
        return a.start_unix < b.start_unix or (a.start_unix == b.start_unix and a.place < b.place)
    end
    table.sort(other_talks, sort_talks)
    print("found " .. #other_talks .. " other talks")
end

local function view_next_talk(starts, ends, config, x1, y1, x2, y2, events)
    local font_size = config.font_size or 70
    local align = config.next_align or "left"
    local abstract = config.next_abstract
    local default_color = {helper.parse_rgb(config.color or "#ffffff")}

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local x, y = 0, 0

    local col1, col2

    local time_size = font_size
    local title_size = font_size
    local abstract_size = math.floor(font_size * 0.8)
    local speaker_size = math.floor(font_size * 0.8)

    local dummy = "in XXXX min"
    if align == "left" then
        col1 = 0
        col2 = 0 + font:width(dummy, time_size)
    else
        col1 = -font:width(dummy, time_size)
        col2 = 0
    end

    local y_start = y

    if #schedule == 0 then
        text(col2, y, "Fetching events...", time_size, rgba(default_color,1))
        -- Add the height of the text
        y = y + time_size
    elseif not current_talk then
        text(col2, y, "No more scheduled events in this venue.", time_size, rgba(default_color,1))
        -- Time
        text(col2 - 120, y, ":(", time_size, rgba(default_color,1))
        y = y + time_size
    else
        pp(current_talk)
        -- Time
        text(col1, y, current_talk.start_str, time_size, rgba(default_color,1))

        -- Delta
        local delta = current_talk.start_unix - api.clock.unix()
        local talk_time
        if delta > 180*60 then
            talk_time = string.format("in %d h", math.floor(delta/3600))
        elseif delta > 0 then
            talk_time = string.format("in %d min", math.floor(delta/60)+1)
        else
            talk_time = "Now"
        end

        local y_time = y+time_size
        text(col1, y_time, talk_time, time_size, rgba(default_color,1))

        local y_duration = y_time + (time_size * 2)
        text(col1, y_duration, duration_text(current_talk.duration), math.floor(time_size * 0.7), rgba(default_color, .8))

        local y_track_title = y_time + (time_size * 3) -- Have a nice gap between time and track

        -- Scale event track name to the width we've got in the left column
        local track_width = 10000 -- crazy max size
        local track_size  = time_size
        while (track_width > col2 - 50) do
            track_size = math.floor(track_size * 0.7)
            track_width = font:width(current_talk.track.display_name, track_size)
        end
        -- track title
        text(col1, y_track_title, current_talk.track.display_name, track_size, rgba(current_talk.track.color, 1))

        -- Title

        local lines = wrap(current_talk.title, font, title_size, a.width - col2)
        for idx = 1, math.min(5, #lines) do
            text(col2, y, lines[idx], title_size, rgba(default_color,1))
            y = y + title_size
        end
        y = y + 20

        -- Abstract
        if abstract then
            local initial_abstract_size = abstract_size
            local lines = wrap(current_talk.abstract, font, abstract_size, a.width - col2)
            print("shrunk abstract to ", #lines, " ", abstract_size)
            -- try and make the abstrack smaller till it fits on the screen nicely.
            local max_lines = 6
            local max_full_height = (initial_abstract_size * max_lines)
            while ((abstract_size * #lines > max_full_height) and (abstract_size > 40)) do
                abstract_size = math.floor(abstract_size * 0.8)
                lines = wrap(current_talk.abstract, font, abstract_size, a.width - col2)
                print("shrunk abstract to ", #lines, " ", abstract_size)
            end
            -- If we made it down to tiny 40px font size, just elipse it.
            if (abstract_size * #lines > max_full_height) then
                max_lines = (math.floor(max_full_height / abstract_size))
                lines[max_lines] = lines[max_lines]:sub(1, -3) .. "..."
                print("still too big ", max_lines)
                print(#lines[max_lines])
            end
            for idx = 1, math.min(max_lines, #lines) do
                text(col2, y, lines[idx], abstract_size, rgba(default_color,1))
                y = y + abstract_size
            end
            y = y + 30
        end

        -- Speakers
        for idx = 1, #current_talk.speakers do
            text(col2, y, current_talk.speakers[idx], speaker_size, rgba(default_color,.8))
            y = y + speaker_size
        end

        y = y + speaker_size
        -- Age range
        if string.len(current_talk.age_range) > 0 then
            text(col2, y, current_talk.age_range, speaker_size, rgba(default_color,.8))
        end

        -- Add the height of the age range
        y = y + speaker_size
    end
    -- Then draw the track bar
    local background = fallback_track_background
    if current_talk then
        background = current_talk.track.background
    end
    a.add(anims.moving_image_raw(
        S, E, background, col2 - 25, y_start, col2-12, y
    ))

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_room_info(starts, ends, config, x1, y1, x2, y2, events)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local x, y = 0, 0

    local info_lines = current_room.info_lines

    local w = 0
    for idx = 1, #info_lines do
        local line = info_lines[idx]
        w = math.max(w, font:width(line.name, font_size))
    end
    for idx = 1, #info_lines do
        local line = info_lines[idx]
        if line == "splitter" then
            y = y + math.floor(font_size/2)
        else
            text(x, y, line.name, font_size, r,g,b,1)
            text(x + w + 40, y, line.value, font_size, r,g,b,1)
            y = y + font_size
        end
    end

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_event_list(starts, ends, config, x1, y1, x2, y2, events)
    local title_size = config.font_size or 70
    local align = config.all_align or "left"
    local default_color = {helper.parse_rgb(config.color or "#ffffff")}

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends

    local time_size = title_size
    local info_size = math.floor(title_size * 0.7)
    local duration_size = math.floor(info_size * 0.8)

    local split_x
    if align == "left" then
        split_x = font:width("In 60 min", title_size)+title_size
    else
        split_x = 0
    end

    local x, y = 0, 0

    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end
    if #schedule == 0 then
        text(split_x, y, "Fetching events...", title_size, rgba(default_color,1))
        print("Schedule is empty")
    elseif #events == 0 and #schedule > 0 and sys.now() > 30 then
        text(split_x, y, "No more scheduled events.", title_size, rgba(default_color,1))
        print("No more events in the schedule")
        -- Time
        text(split_x - 120, y, ":(", time_size, rgba(default_color,1))
        -- Then draw the track bar
        a.add(anims.moving_image_raw(
            S, E, fallback_track_background,
            split_x-25, y, split_x-12,
            y + time_size + 3
        ))
        y = y + time_size
    end
    local now = api.clock.unix()
    for idx = 1, #events do
        local talk = events[idx]

        local title_lines = wrap(
            talk.title,
            font, title_size, a.width - split_x
        )

        local info_lines = wrap(
            room_name_or_any(talk) .. talk.speaker_intro,
            font, info_size, a.width - split_x
        )

        if y + #title_lines * title_size + info_size > a.height then
            break
        end

        -- Start of this event's height
        local y_start = y

        -- time
        local time
        local til = talk.start_unix - now
        if til > -60 and til < 60 then
            time = "Now"
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, rgba(default_color, 1))
        elseif til > 0 and til < 15 * 60 then
            -- ceil so that if the clock shows 13:50, it's 10 mins away, not 9.
            time = string.format("In %d min", math.ceil(til/60))
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, rgba(default_color, 1))
        elseif talk.start_unix > now then
            time = talk.start_str
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, rgba(default_color, 1))
        else
            time = string.format("%d min ago", math.floor(-til/60))
            local w = font:width(time, time_size)+time_size
            text(x+split_x-w, y, time, time_size, rgba(default_color,.8))
        end
        -- track title
        local track_text_size = math.floor(time_size * 0.7)
        local width = font:width(talk.track.display_name, track_text_size)+time_size -- Add the width of one time character as a right padding
        text(x+split_x-width, y+time_size, talk.track.display_name, track_text_size, rgba(talk.track.color, 1))


        -- title
        for idx = 1, #title_lines do
            text(x+split_x, y, title_lines[idx], title_size, rgba(default_color,1))
            y = y + title_size
        end
        y = y + 3

        -- info
        for idx = 1, #info_lines do
            text(x+split_x, y, info_lines[idx], info_size, rgba(default_color,.8))
            y = y + info_size
        end

        -- duration / Age range
        local duration = duration_text(talk.duration)


        if string.len(talk.age_range) > 0 then
            duration = duration .. " - " .. talk.age_range
        end

        y = y + 2 -- Needed a little bit more padding at small font
        text(x+split_x, y, duration, duration_size, rgba(default_color,.7))
        -- Add the height of the duration text
        y = y + duration_size

        -- track bar
        a.add(anims.moving_image_raw(
            S, E, talk.track.background,
            x+split_x-25, y_start, x+split_x-12,
            y
        ))

        -- Space ready for the next event
        y = y + 20
    end

    for now in api.frame_between(starts, ends) do
        a.draw(now, x1, y1, x2, y2)
    end
end

local function view_room(starts, ends, config, x1, y1, x2, y2, events)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")

    for now in api.frame_between(starts, ends) do
        local line = current_room.name_short
        info_font:write(x1, y1, line, font_size, r,g,b)
    end
end

local function view_day(starts, ends, config, x1, y1, x2, y2, events)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")
    local align = config.day_align or "left"
    local template = config.day_template or "Day %d"

    for now in api.frame_between(starts, ends) do
        local line = string.format(template, day)
        if align == "left" then
            info_font:write(x1, y1, line, font_size, r,g,b)
        elseif align == "center" then
            local w = info_font:width(line, font_size)
            info_font:write((x1+x2-w) / 2, y1, line, font_size, r,g,b)
        else
            local w = info_font:width(line, font_size)
            info_font:write(x2-w, y1, line, font_size, r,g,b)
        end
    end
end

local function view_clock(starts, ends, config, x1, y1, x2, y2, events)
    local font_size = config.font_size or 70
    local r,g,b = helper.parse_rgb(config.color or "#ffffff")
    local align = config.clock_align or "left"

    for now in api.frame_between(starts, ends) do
        local line = api.clock.human()
        if align == "left" then
            info_font:write(x1, y1, line, font_size, r,g,b)
        elseif align == "center" then
            local w = info_font:width(line, font_size)
            info_font:write((x1+x2-w) / 2, y1, line, font_size, r,g,b)
        else
            local w = info_font:width(line, font_size)
            info_font:write(x2-w, y1, line, font_size, r,g,b)
        end
    end
end

local function view_track_key(starts, ends, config, x1, y1, x2, y2, events)

    local a = anims.Area(x2 - x1, y2 - y1)

    local S = starts
    local E = ends
    local function text(...)
        return a.add(anims.moving_font(S, E, font, ...))
    end

    local font_size = config.font_size or 35
    font_size = font_size / 2
    local text_color = {helper.parse_rgb(config.color or "#ffffff")}
    local x = x1
    for idx, track in ipairs(tracks) do
        local w = font:width(track.display_name, font_size)+font_size
        text(x, y1, track.display_name, font_size, rgba(text_color, 1))
        x = x + w
    end
end

function M.task(starts, ends, config, x1, y1, x2, y2)
    check_next_talk()
    local event_datasource = {
        other_talks = other_talks,
        all_talks = next_talks,
        attendee_events = next_attendee_events,
        next_workshops = next_workshops,
        none = nil
    }
    local mode = config.mode or 'all_talks'
    print("Rendering screen:", mode)
    return ({
        next_talk = view_next_talk,
        other_talks = view_event_list,
        room_info = view_room_info,
        all_talks = view_event_list,
        attendee_events = view_event_list,
        next_workshops = view_event_list,

        room = view_room,
        day = view_day,
        clock = view_clock,
        track_key = view_track_key
    })[config.mode or 'all_talks'](starts, ends, config, x1, y1, x2, y2, event_datasource[config.mode or 'none'])
end

function M.can_show(config)
    local mode = config.mode or 'all_talks'
    print("probing frab mode", mode)
    -- these can always play
    if mode == "day" or
       mode == "clock" or
       mode == "all_talks" or
       mode == "attendee_events" or
       mode == "next_workshops" or
       mode == "track_key"
    then
        return true
    end
    return not not current_room
end

return M
