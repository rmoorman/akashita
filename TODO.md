# TODO

## Warmup

1. Generate the first bucket name and create it, before checking go-time
    * This ensures that many dependencies are working (ulid, jiffy, hackney, enenra)
1. Generate the file archives before checking go-time
    * Oftentimes the generation takes quite a while

## Batch Emails

1. Send email when a batch of uploads has completed, with metrics
    * Only if an email address is configured (none when testing)
    * Can also log the stats
    * Average upload time
    * Number of objects uploaded
    * Number of buckets completed
    * Capture these in the State record, using a new Metrics record
        - num objects
        - num buckets
        - total upload time

## Assisted Restore

1. An Escript (probably) that takes a bucket name and performs the following:
    * Retrieve all of the objects in the bucket
    * Using the object name (e.g. "photos000001"), assemble the tar file
1. User will then use `tar` with the appropriate flags to extract the files.
