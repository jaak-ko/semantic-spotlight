# Notes: municipality data pipeline migration

We are moving the nightly ETL that loads population, permit and service-request data
from the old cron-driven scripts onto the new orchestrated workflow. Open items: validate
row counts after the cutover, retire the legacy FTP drop, and agree the schema freeze date
with the city IT office. Owner: data platform team.
