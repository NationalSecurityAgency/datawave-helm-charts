# Tests
**Note**: To run tests, make sure you are in the `tests` directory.

| Test Name | Description |
| --------- | ----------- |
| test_pods.py | Verifies the pods are all in the running or succeeded states |
| test_ingest.py | Uploads the test data required for the integration tests, waits for it to process, and then refreshes cache. |
| Test_Query | Runs the follow tests: Verify the end points are working for DataWave (create, next, close); Verify the fields made query-able for the data type myjson (tv data) are query-able; Using a specific event, query specific data from DataWave to verify the data being ingested and pulled out matches it in the before state; and testing various combinations of authorizations. |




## Setup
Before running any tests, make sure to ```pip install -r requirements.txt```.

The Datwave CLI is not published anywhere, so to install that requirement you will need to go to
[Datawave CLI](https://github.com/AFMC-MAJCOM/datawave-cli). There you can download the wheel and install from the
wheel.

## Running the tests
Run `pytest <filename> [-N namespace]` to run individual tests. Run `pytest` to run the full suite of tests.

By default, the tests are running using `localhost`. This means that the `datawave-monolith` pod will need to be
forwarded by default. An alternative to localhost is using `--disable_localhost` to disable localhost and specifying the url via `--url` for the datawave-monolith.

By default the tests use the `datawave` namespace. This can be overridden by passing a `-N` argument with a different namespace. This is important for the pods and ingest test as they uses python Kubernetes library to interact with 
Kubernetes.

### Parameters
| Parameter Name | Description |
| -------------- | ----------- |
| namespace | Set the namespace within Kubernetes to utilize for the pods and ingest tests. |
| disable_localhost | Disable the usage of `localhost:8443`. |
| url | required if localhost is disabled, specifies the url to use when calling the datawave-monolith. |
| use_ip | Enables the usage of the pods `IP:port` for interacting with datawave. Overrides the url option. localhost will need to be disabled for this parameter to take effect. |

### Generating a Report
Run `pytest --html=<path to report name.html> --css=assets/report.css` to run the full suite of tests and create a report.

### Base URL
By default, all of the tests will hit the hostname ``. This can be overridden by setting the environment variable `DWV_URL` and it will always use that unless you unset that variable.
