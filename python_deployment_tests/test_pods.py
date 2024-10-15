from copy import copy
from datetime import datetime
from logging import Logger

import pytest
from kubernetes import client
from kubernetes.client import CoreV1Api
from kubernetes.client.models.v1_pod import V1Pod

from datawave_cli.utilities.utilities import Retry, setup_logger
from helpers.utilities import assert_test, log_test_start
from helpers.constants import namespace



@pytest.fixture(scope='module')
def pods(kube_client: CoreV1Api, log: Logger):
    """Returns all pods in the namespace defined in constants.py with a label of testing=true

    Parameters
    ----------
    kube_client: CoreV1Api
        The k8s client supplied by the kube_client fixture.

    log: Logger
        The log object for logging.

    Returns
    -------
    list[V1Pod]
        A list of pods

    Notes
    -----
    Relies on two fixtures defined in conftest.py
    """
    try:
        all_pods = kube_client.list_namespaced_pod(namespace=namespace).items

        log.debug(f'Found the following pods: {[pod.metadata.name for pod in all_pods]}')

        if (not all_pods):
            raise RuntimeError('No valid pods found!')
        yield all_pods
    except Exception as e:
        msg = f"Failed to retrieve pod list: {e}"
        assert_test(False, log, fail_msg=msg)


def check_pod_readiness(pod: V1Pod, log: Logger) -> bool:
    """Checks the readiness of a pod by checking if it is in a 'Running' state

    Parameters
    ----------
    pod: V1Pod
        Pod to check the readiness of.

    log: Logger
        The Logger object for logging to.

    Returns
    -------
    boolean:
        Is pod in 'Running' state.
    """

    # get an update on the pod
    core = client.CoreV1Api()
    pod = core.read_namespaced_pod(name=pod.metadata.name, namespace=namespace)

    name = pod.metadata.name
    status = pod.status.phase

    log.debug(f'Pod ({name}) is in state ({status})')
    containers_not_running = None
    if (status == 'Running'):
        container_statuses = pod.status.container_statuses
        containers_not_running = [c_status.name for c_status in container_statuses if c_status.state.running is None]
        log.debug(f"Containers in pod {name} that are not running: [{containers_not_running}]")
    return status == 'Running' and not any(containers_not_running)


@Retry(time_limit_min=10, delay_sec=5)
def check_all_pod_readiness(pods: list[V1Pod], log: Logger):
    """Iterates all provided pods to check readiness.

    Retry wrapper will recheck pods every 5 seconds for 10 minutes. This is a
    blocking wait.

    Parameters
    ----------
    pods: list[V1Pod]
        List of pods to be checked. Running pods are removed from list.

    log: Logger
        The Logger object for logging to.

    Raises
    ------
    RuntimeError
        Raised if any pod is found in a state that is not 'Running'.

    Notes
    -----
    This is a blocking operation. The program will wait until the retries are
    finished before exiting this function.

    This method modifies the list passed in and removes successful pods such that
    successive calls run with same input, such as from retry wrapper, will skip
    running pods.
    """
    log.info(f'Checking {[p.metadata.name for p in pods]}')
    failed_pods = []
    for pod in copy(pods):
        pod_ready = check_pod_readiness(pod, log)
        if (pod_ready):
            pods.remove(pod)
        else:
            failed_pods.append(pod.metadata.name)
    log.debug('-' * 120)
    if (failed_pods):
        msg = f'Following pods not running yet: {failed_pods}'
        log.info(msg)
        raise RuntimeError(msg)


def test_all_pod_readiness(pods: list[V1Pod], log: Logger):
    """Tests the readiness for all pods."""
    log_test_start(log, test_all_pod_readiness)
    pods_copy = copy(pods)
    failed = None
    try:
        check_all_pod_readiness(pods_copy, log)
    except (RuntimeError, TimeoutError) as error:
        failed = repr(error)

    assert_test(not failed, log, pass_msg='All pods Running!', fail_msg=failed)
