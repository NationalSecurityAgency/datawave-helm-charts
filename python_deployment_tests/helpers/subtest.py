from logging import Logger
from helpers.utilities import log_test_start, assert_test


class Test:
    """Represents a test case with multiple subtests.

    Parameters
    ----------
    log: Logger
        The logger object to log test information.

    test_func: str
        The test function being ran. Included for logging purposes.

    Attributes
    ----------
    results: dict
        A dictionary to store subtest results.

    log: Logger
        The logger object to log test information.
    """
    def __init__(self, log: Logger, test_func: callable):
        self.results = {}
        self.log = log
        log_test_start(log, test_func)

    def subtest(self, name: str):
        """Context manager to define a subtest.

        Parameters
        ----------
        name: str
            The name of the subtest.

        Returns
        -------
        A context manager for the subtest.
        """
        return _SubtestContextManager(self, name)

    def add_result(self, subtest: str, result: bool):
        """Add result of a subtest to the results dictionary.

        Parameters
        ----------
        subtest: str
            The name of the subtest.

        result: bool
            The result of the subtest.
        """
        self.results[subtest] = result

    @property
    def passed(self):
        """Checks if all subtests passed.

        Returns
        -------
        bool:
            True if all subtests passed, False otherwise.
        """
        passed = all(self.results.values())
        failed_subtests = [subtest for subtest, res in self.results.items() if not res]
        assert_test(passed, self.log, pass_msg="All subtests passed!",
                    fail_msg=f'Following subtests failed {failed_subtests}')
        return passed


class _SubtestContextManager:
    """Context manager for a subtest within a Test case.

    Parameters
    ----------
    test: Test
        The parent Test object.
    name: str
        The name of the subtest.
    """
    def __init__(self, test: Test, name: str):
        self.test = test
        self.name = name

    def __enter__(self):
        """Logs the start of the subtest.
        """
        self.test.log.info(f'Starting subtest: {self.name}')

    def __exit__(self, exc_type, exc_value, traceback):
        """Logs the result of the subtest and adds it to the parent Test object's results.

        Notes
        -----
        Suppresses error so raised exceptions will not propogate and need caught as we handle logging them here.
        """
        if exc_type is None:
            self.test.log.info(f"Subtest '{self.name}' passed!")
            self.test.add_result(self.name, True)
        else:
            self.test.log.error(f"Subtest '{self.name}' failed: {exc_value}.")
            self.test.add_result(self.name, False)
        return True
