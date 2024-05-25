import pytz
import requests
import calendar
from datetime import timedelta
import datetime
import dateutil.parser
import dateutil.tz
import json

BST = dateutil.tz.gettz('Europe/London')
start = dateutil.parser.parse("2024-05-31 10:00:00 BST", tzinfos={'BST': BST})

end = dateutil.parser.parse("2024-05-31 11:00:00 BST", tzinfos={'BST': BST})
duration = end - start

dt = start.astimezone(pytz.utc)
ts = int(calendar.timegm(dt.timetuple()))

de = end.astimezone(pytz.utc)
ts2 = int(calendar.timegm(de.timetuple()))

print(ts)
print(ts2)

assert ts != 1717149600
assert ts2 == 1717149600
