-- Job Crawling Pipeline for Zoho Recruit Sites
-- Two-stage crawl: list pages -> detail pages
--
-- Stage 1: Crawl main pages to get job IDs
-- Stage 2: Crawl individual job pages for full details
--
-- Sites: carrieres.os4techno.com, recruit.srilankan.com

LOAD 'build/release/extension/crawler/crawler.duckdb_extension';

-- Two-stage crawl: listing pages -> detail pages via LATERAL crawl_url()
WITH listing_pages AS (
    SELECT c.url, c.html.document as doc
    FROM (VALUES ('https://carrieres.os4techno.com/'), ('https://recruit.srilankan.com/')) AS t(seed_url),
         LATERAL crawl_url(seed_url) c
    WHERE c.status = 200
),
job_urls AS (
    SELECT format('{}jobs/Careers/{}', url, job_id) as job_url
    FROM (
        SELECT url, unnest(htmlpath(doc, 'input#jobs@value[*].id')::BIGINT[]) as job_id
        FROM listing_pages
    )
),
job_pages AS (
    SELECT c.url, htmlpath(c.html.document, 'script@$jobs[0]') as job
    FROM job_urls, LATERAL crawl_url(job_url) c
    WHERE c.status = 200
)
SELECT url, job->>'id' as id, job->>'Posting_Title' as posting_title,
       job->>'City' as city, job->>'State' as state, job->>'Country' as country,
       job->>'Industry' as industry, job->>'Job_Type' as job_type,
       job->>'Work_Experience' as work_experience,
       (job->>'Remote_Job')::BOOLEAN as remote_job,
       (job->>'Date_Opened')::DATE as date_opened,
       job->>'Salary' as salary, job->>'Job_Description' as job_description
FROM job_pages;
