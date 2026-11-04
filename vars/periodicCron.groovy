// Returns the periodic cron schedule for a given Jenkins job name.
//
// Every Jenkins job now returns '' (no schedule): the tests run in GitHub Actions instead
// (.github/workflows/aws-integ-tests.yml, local-integ-tests.yml, k8s-matrix-tests.yml). Jenkins
// drops a job's cron trigger the next time that job runs with this library.
def call(String jobName) {
    return ''
}
