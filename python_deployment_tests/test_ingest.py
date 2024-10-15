import re
import subprocess
import xml.etree.ElementTree as ET
from io import StringIO
from logging import Logger
from types import SimpleNamespace

import pytest
import pandas as pd

from datawave_cli.accumulo_interactions import AccumuloInteractions
from datawave_cli.ingest_interactions import check_app_statuses, get_accumulo_appstates, check_for_file
from datawave_cli.utilities.utilities import Retry
from datawave_cli.utilities.pods import yarn_rm_info, hdfs_nn_info, get_specific_pod
from helpers.utilities import log_test_start, assert_test
from helpers.constants import namespace, cert, use_ip, use_localhost, url

# ---- Changable values ----
"""
- To change what namespace the tests is running against, change the namespace
    variable in the constants.py file.
-
"""
src_file = "resources/custom-tv-shows.json"
data_folder = 'myjson'


@pytest.fixture()
def accumulo_interactions(log: Logger):
    sns = SimpleNamespace(cert=cert[0], key=cert[1], namespace=namespace, localhost=use_localhost,
                          ip=use_ip, header={}, url=url)
    ai = AccumuloInteractions(sns, log)
    yield ai

@pytest.fixture()
def refresh_cache(log: Logger, accumulo_interactions: AccumuloInteractions):
    """Fixture to handle teardown of ingest test.

    After ingesting data, the `datawave.metadata` needs to be refreshed for new
    data types. If either refresh fails to complete within 5 minutes an error
    will be logged and the test will exit as it cannot proceed with query testing
    without both refreshes completing.
    """
    # setup
    yield None
    # Teardown: Need to refresh accumulo cache when it's ready
    log.info('Attempting to refresh accumulo cache')
    try:
        accumulo_interactions.reload_accumulo_cache()
        check_cache_ready(log, accumulo_interactions)
        log.debug("\nWhat about refresh?\nYou've already had it.\nWe've had one, yes. What about second refresh?")
        accumulo_interactions.reload_accumulo_cache()
        check_cache_ready(log, accumulo_interactions)
    except TimeoutError as e:
        msg = 'Cache failed to refresh. You will need to do so manually before proceeding.'
        log.error(e)
        log.warning(msg)
        pytest.exit(msg, returncode=2)
    else:
        log.info('Cache refreshed and is now ready for queries.')


@Retry(time_limit_min=5, delay_sec=10)
def check_cache_ready(log: Logger,  accumulo_interactions: AccumuloInteractions):
    """Checks if the accumulo cache has been refreshed
    """
    root = ET.fromstring(accumulo_interactions.view_accumulo_cache(cert, namespace, log))
    table = root.find(".//{http://webservice.datawave.nsa/v1}TableCache[@tableName='datawave.metadata']")
    if '1970' in table.attrib['lastRefresh']:
        msg = f'Cache not refreshed for {table.attrib["tableName"]} yet.'
        log.debug(msg)
        raise UserWarning(msg)


def check_final_state(log: Logger):
    """Checks the final state of the most recent application.

    Unfortunately we cannot guarantee that final application is always the first or last object in the list
    so we need to look at their names and find the highest number at the end of the job name and check that final state.

    The code for this is largely the same as the check statuses we're just looking at more than just the one column.

    This function does not use the Retry wrapper because if it is in an invalid state the entire test needs to be reran
    """
    cmd = 'yarn application -list -appStates ALL'

    resp = get_specific_pod(yarn_rm_info, namespace).execute_cmd(cmd)
    resp = re.sub(' *', '', resp)
    df = pd.read_csv(StringIO(resp), sep='\t', skiprows=3, header=0)
    df = df[['Application-Id', 'Final-State']]
    log.debug(df)

    df['app_number'] = df['Application-Id'].str.extract(r'_(\d+)$').astype(int)
    newest_application = df.loc[df['app_number'].idxmax()]
    final_state = newest_application['Final-State']
    if final_state != 'SUCCEEDED':
        msg = f'Most recent application {final_state}!'
        log.error(msg)
        raise RuntimeError(msg)



def test_datawave_ingest(log: Logger, refresh_cache):
    """Tests the ingest of data into DataWave.
    Step 1) Get number of existent apps in Hadoop Yarn
    Step 2) copy data into DataWave HDFS
    Step 3) Check the Hadooop Yarn Applications
    """
    log_test_start(log, test_datawave_ingest)
    # get baseline number of statuses
    starting_statuses = get_accumulo_appstates(namespace=namespace, log=log)
    num_of_starting_statuses = len(starting_statuses)
    log.info(f"Number of Apps before starting ingest: {num_of_starting_statuses}")

    test_filename = f"test-{num_of_starting_statuses+1}.json"
    
    # copy data file to hdfs node this also checks for file and copies into HDFS
    hdfs_nn_pod = get_specific_pod(hdfs_nn_info, namespace)
    cmd = [
        'kubectl',
        'cp',
        '-n',
        namespace,
        src_file,
        f"{hdfs_nn_pod.podname}:/tmp/{test_filename}"
    ]

    log.debug(cmd)
    log.info("Running kubectl copy...")
    proc = subprocess.run(cmd)
    log.info(proc)

    if check_for_file(test_filename, namespace, log):
        log.warning("Test data file was not found inside hadoop pod. Cannot continue with ingest script.")
        raise RuntimeError("Test file was not found within the pod, cannot continue with ingest test.")

    # copy local pod file to hdfs
    cmd = f'hdfs dfs -put /tmp/{test_filename} hdfs://hdfs-nn:9000/data/{data_folder}'
    log.info("Running copy into HDFS...")
    resp = hdfs_nn_pod.execute_cmd(cmd)
    log.info(resp)
    log.info("copy into HDFS complete...")

    failed = None
    # Check Hadoop yarn for any failed or running applications
    try:
        log.info("Checking application statuses")
        check_app_statuses(num_of_starting_statuses, namespace, log)
    except (RuntimeError, TimeoutError) as e:
        failed = repr(e)

    # Check final state of most recent app is succeeded
    try:
        log.info("Checking application final state")
        check_final_state(log)
    except RuntimeError as e:
        failed = repr(e)

    assert_test(not failed, log, fail_msg=failed)
    
