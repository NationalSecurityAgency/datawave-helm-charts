import pytest
import logging
from datetime import datetime
from pathlib import Path
from kubernetes import client, config
from logging.handlers import TimedRotatingFileHandler
import helpers.constants as consts


def pytest_collection_modifyitems(session, config, items):
    """Reorganize collected tests to ensure they run in a specific order.

    This function is called after pytest collects the tests. By default, pytest
    collects tests alphabetically by file, followed by the order within each file.
    However, our test suite requires a specific execution order. For instance, pod
    readiness tests must run before ingest tests since query tests depend on them.

    We specify the desired order of test files in the `ordered_files` list. The
    function builds `reordered_items` with tests from these files in the specified
    order, followed by tests from any unlisted files in their original order.

    The function modifies `items` in place by replacing it with `reordered_items`.
    """
    ordered_files = ["test_pods.py", "test_ingest.py"]

    reordered_items = []
    for file_name in ordered_files:
        for item in items[:]:
            if item.path.name == file_name:
                reordered_items.append(item)
                items.remove(item)

    reordered_items += items
    items[:] = reordered_items


@pytest.fixture(scope="module")
def kube_client():
    """Fixture for creating a Kubernetes client instance.

    This fixture loads the Kubernetes configuration and initializes a CoreV1Api client.

    Returns
    -------
    client.CoreV1Api:
        A Kubernetes client instance.
    """
    config.load_kube_config()
    kube_client = client.CoreV1Api()
    yield kube_client


def pytest_addoption(parser):
    """Adds command line arguments to the test suite using the built in parser fixture

    Note that parser.addoption has the same attributes as argparse's add_argument
    """
    # -n is reserved so -N is used instead
    parser.addoption("-N", "--namespace", action="store", default=consts.namespace)
    parser.addoption("--use_ip", action="store_true")
    parser.addoption("--disable_localhost", action="store_false")
    parser.addoption("--url", action="store")


@pytest.hookimpl(tryfirst=True)
def pytest_configure(config):
    """Set the namespace from the commandline argument.

    Uses the default value from helpers.constants.namespace if not provided
    """
    consts.namespace = config.getoption("namespace")
    consts.use_ip = config.getoption("use_ip")
    consts.use_localhost = config.getoption("disable_localhost")
    consts.url = config.getoption("url")


# Logging stuff
main_logger = logging.getLogger('integration_tests')
main_logger.setLevel(logging.INFO)

log_dir = Path('logs/local')
log_dir.mkdir(parents=True, exist_ok=True)

now = datetime.now().strftime('%Y%m%d_%H%M%S')
log_path = log_dir.joinpath(f'test_{now}.log')

formatter = logging.Formatter('%(asctime)s : %(name)s : %(levelname)s - %(message)s')

fh = logging.FileHandler(log_path)
fh.setLevel(logging.INFO)
fh.setFormatter(formatter)

main_logger.addHandler(fh)


@pytest.fixture(scope="module")
def log(request):
    log_name = request.module.__name__
    test_logger = logging.getLogger(f'integration_tests.{log_name}')
    test_logger.setLevel(logging.DEBUG)

    test_log_path = log_dir.joinpath(f'{log_name}.log')
    test_formatter = logging.Formatter('%(asctime)s : %(levelname)s - %(message)s')

    rfh = TimedRotatingFileHandler(test_log_path, when='midnight', interval=1, backupCount=3)
    rfh.setLevel(logging.DEBUG)
    rfh.setFormatter(test_formatter)

    test_logger.addHandler(rfh)

    # 2588 is the full block character
    test_logger.info('\u2588' * 120)

    yield test_logger

    test_logger.removeHandler(rfh)