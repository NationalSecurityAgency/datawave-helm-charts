from logging import Logger

import pytest

from helpers.constants import ascii_fail, ascii_start, ascii_success


def log_test_start(log, test_method):
    """Standardizes a test start log statement"""
    log.info(ascii_start)
    log.info(f'{test_method.__name__}: {test_method.__doc__}')


def assert_test(check: bool, log: Logger, pass_msg: str = '', fail_msg: str = ''):
    """Asserts the result of a test condition and logs the results"""
    if check:
        log.info(f"Test Succeeded. {pass_msg}")
        log.info(ascii_success)
    else:
        msg = f"Test Failed. {fail_msg}"
        log.error(msg)
        log.error(ascii_fail)
        pytest.fail(msg)


if __name__ == '__main__':
    pass
