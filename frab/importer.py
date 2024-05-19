import pytz
import requests
import calendar
from datetime import timedelta

import dateutil.parser
import defusedxml.ElementTree as ET
import json

def get_schedule(url, group):
    def load_events_emf_json(json_str):
        def to_unixtimestamp(dt):
            ts = int(calendar.timegm(dt.timetuple()))
            return ts

        def all_events():
            return json.loads(json_str)

        parsed_events = []
        for event in all_events():
            start = dateutil.parser.parse(event["start_date"])

            end = dateutil.parser.parse(event["end_date"])
            duration = end - start

            speaker = event['speaker'].strip() if event['speaker'] else None
            if speaker and event["pronouns"]:
                speaker += f" - {event['pronouns']}"
            parsed_events.append(dict(
                start = start,
                start_str = start.strftime('%H:%M'),
                end_str = end.strftime('%H:%M'),
                start_unix  = to_unixtimestamp(start),
                end_unix = to_unixtimestamp(end),
                duration = int(duration.total_seconds() / 60),
                title = event['title'],
                track = event['type'],
                place = event['venue'],
                abstract = event['description'],
                speakers = [
                    speaker
                ] if speaker else [],
                lang = '', # Not in EMF struct
                id = str(event['id']),
                is_from_cfp = event['is_from_cfp'],
                group = group
            ))
        return parsed_events



    def load_events(xml):
        def to_unixtimestamp(dt):
            dt = dt.astimezone(pytz.utc)
            ts = int(calendar.timegm(dt.timetuple()))
            return ts
        def text_or_empty(node, child_name):
            child = node.find(child_name)
            if child is None:
                return u""
            if child.text is None:
                return u""
            return unicode(child.text)
        def parse_duration(value):
            h, m = map(int, value.split(':'))
            return timedelta(hours=h, minutes=m)

        def all_events():
            schedule = ET.fromstring(xml)
            for day in schedule.findall('day'):
                for room in day.findall('room'):
                    for event in room.findall('event'):
                        yield event

        parsed_events = []
        for event in all_events():
            start = dateutil.parser.parse(event.find('date').text)
            duration = parse_duration(event.find('duration').text)
            end = start + duration

            persons = event.find('persons')
            if persons is not None:
                persons = persons.findall('person')

            parsed_events.append(dict(
                start = start.astimezone(pytz.utc),
                start_str = start.strftime('%H:%M'),
                end_str = end.strftime('%H:%M'),
                start_unix  = to_unixtimestamp(start),
                end_unix = to_unixtimestamp(end),
                duration = int(duration.total_seconds() / 60),
                title = text_or_empty(event, 'title'),
                track = text_or_empty(event, 'track'),
                place = text_or_empty(event, 'room'),
                abstract = text_or_empty(event, 'abstract'),
                speakers = [
                    unicode(person.text.strip())
                    for person in persons
                ] if persons else [],
                lang = text_or_empty(event, 'language'),
                id = event.attrib["id"],
                group = group,
            ))
        return parsed_events

    r = requests.get(url)
    r.raise_for_status()
    schedule = r.content
    if url.endswith('.json'):
        return load_events_emf_json(schedule)
    return load_events(schedule)
