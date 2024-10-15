import json
from re import L
from typing import Any
from logging import Logger
from types import SimpleNamespace

import pytest

from datawave_cli.query_interactions import QueryParams, QueryInteractions
from helpers.subtest import Test
from helpers.utilities import assert_test, log_test_start
from helpers.constants import namespace, use_ip, cert, ascii_fail, use_localhost, url


@pytest.fixture()
def query_interactions(log: Logger):
    sns = SimpleNamespace(cert=cert[0], key=cert[1], namespace=namespace, localhost=use_localhost, ip=use_ip,
                          header={}, url=url)
    qi = QueryInteractions(sns, log)
    yield qi


def test_query(log: Logger, query_interactions: QueryInteractions):
    """Tests that query can be preformed"""
    log_test_start(log, test_query)
    query_params = QueryParams(query_name="test-query",
                               query="GENRES == 'action' || GENRES =~ 'adv.*'",
                               auths="BAR,FOO,PRIVATE,PUBLIC")
    args = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                          auths=query_params.auths, filter=None, output=None, decode_raw=False)
    results = query_interactions.perform_query(args)
    event_count = results['metadata']['Returned Events']

    assert_test(event_count, log, pass_msg=f'{event_count} returned events.',
                fail_msg='Check data was ingested properly.')


def test_query_fields(log: Logger,  query_interactions: QueryInteractions):
    """Tests that queryable fields are queryable"""
    log_test_start(log, test_query_fields)
    fields = ['NAME', 'ID', 'EXTERNALS_THETVDB', 'EXTERNALS_TVRAGE', 'EXTERNALS_IMDB',
              'GENRES', 'NETWORK_NAME', 'TYPE', 'STATUS', 'RUNTIME', 'URL']
    with open('resources/1-custom-event.json', 'r') as data:
        test_data = json.load(data)

    missing_fields = set()
    for field in fields:
        log.info(f"Testing query on field {field}")

        value = dive_into_data(test_data, field.lower().split('_'))
        value = extract_value(value)
        log.debug(f"Test value for field {field} is: {value}")

        query_params = QueryParams(query_name="test-query",
                                   query=f"{field} == '{value}'",
                                   auths="BAR,FOO,PRIVATE,PUBLIC")
        args = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                               auths=query_params.auths, filter=None, output=None, decode_raw=False)
        results = query_interactions.perform_query(args)
        event_count = results['metadata']['Returned Events']
        if not event_count:
            log.error(f'Failed to find any results for {field}!')
            missing_fields.add(field)
        else:
            log.info(f'Successfully queried {field}.')

    assert_test(not missing_fields, log, pass_msg=f'All fields successfully queried.',
                fail_msg=f'Following fields did not query successfully: {missing_fields}.')


def dive_into_data(data: dict | list, keys: list) -> Any:
    """Scours a dictionary using the given keys to find the correlated value.

    Parameters
    ----------
    data: Dict | List
        The object to search through.

    keys: List
        The list of keys to utilize when searching through the dictionary.
        The size of the list should not exceed the depth of the dictionary.

    Returns
    -------
    Any
        The value corresponding to the provided keys in the dictionary.
        If the value is a list, it returns the list itself.
        If the value is not found, it returns None.

    Notes
    -----
    - If the provided data is a list, it iterates over each element in the list
      and applies the same operation recursively.
    - If the length of keys is 1, it directly retrieves the value corresponding
      to the first key. If the value is a list, it returns the list itself.
    - If the first key exists in the dictionary, it recurses into the next level
      of the dictionary using the next key in keys.
    - If none of the above conditions are met, it checks if any key in the
      current level of the dictionary contains the first key and continues
      searching recursively. This is to handle the stupid _ prepended keys.
    """
    if isinstance(data, list):
        return_data = []
        for v in data:
            return_data.append(dive_into_data(v, keys))
        return return_data
    elif (len(keys) == 1):
        if isinstance(data[keys[0]], list):
            return data[keys[0]]
        else:
            return str(data[keys[0]])
    elif keys[0] in data:
        return dive_into_data(data[keys[0]], keys[1:])
    else:
        for k in data.keys():
            if keys[0] in k:
                return dive_into_data(data[k], keys[1:])


def extract_value(obj: list | set | tuple | Any) -> Any:
    """Extracts the value of a length 1 list-like object if possible.

    If `obj` is a length one list-like object (ie list, set, tuple) this function
    will extract the value and return it. If the `obj` has more than one element
    or is not iterable, the original object will be returned.

    Parameters
    ---------
    obj: List, Set, or Tuple
        The object to attempt extraction on.

    Returns
    -------
    Any:
        The extracted object if possible, otherwise the original object.
    """
    try:
        value = next(iter(obj))
        if isinstance(obj, (list, set, tuple)) and len(obj) == 1:
            return value
    except TypeError:
        pass
    return obj


def test_query_data(log: Logger, query_interactions):
    """Tests that the data queried matches the data ingested"""
    log_test_start(log, test_query_data)
    with open('resources/1-custom-event.json', 'r') as data:
        ingested_data = json.load(data)
    ingested_data = _lowercase(ingested_data)

    query_params = QueryParams(query_name="test-query",
                               query=f"NAME == 'The Singles Show'",
                               auths="BAR,FOO,PRIVATE,PUBLIC")
    args = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                           auths=query_params.auths, filter=None, output=None, decode_raw=False)
    results = query_interactions.perform_query(args)
    event_count = results['metadata']['Returned Events']
    if event_count != 1:
        msg = f'Expected 1 event, found {event_count}!'
        log.error(msg)
        log.error(ascii_fail)
        pytest.fail(msg)

    fields = results['events'][0]
    # Combine all the same name fields found in the query
    fields_combined = {}
    for key, value in fields.items():
        field_name = key.lower()

        if isinstance(value, list):
            # no need to create new list
            fields_combined[field_name] = [v.lower() for v in value]
        else:
            fields_combined[field_name] = value.lower()

    # Grab the value from the test data and the query data and compare
    # the two values to make sure they match.
    passed = True
    dw_only_keys = {'record_id', 'load_date', 'orig_file', 'term_count'}

    for key, value in fields_combined.items():
        log.info(f"Comparing {key}...")
        if '_' in key:
            keys = key.lower().split('_')
            ingested_value = dive_into_data(ingested_data, keys)
            if ingested_value is None:
                if key not in dw_only_keys:
                    # No ingest data field was found, log it and keep going.
                    log.warning(f"{key} not found in ingested data...")
                    passed = False
                continue
        else:
            ingested_value = ingested_data[key.lower()]

        # Handle if any test data are lists, since DataWave is smart
        # and doesn't duplicate data of same col name and same value.
        # Convert the lists to sets to eliminate dups and to make comparison
        # easier for un-ordered data.
        if isinstance(ingested_value, list) and len(ingested_value) == 1:
            ingested_value = ingested_value[0]
        elif isinstance(ingested_value, list):
            ingested_value = set(ingested_value)
            if (isinstance(value, list)):
                value = set(value)
            else:
                value = {value}

        # Compare the two values, need to check for inclusion because of time object shenanigans
        if ingested_value != value and ingested_value not in value:
            log.error(f"Ingested value, {ingested_value}, does not match queried value, {value}!")
            passed = False
        else:
            log.info(f"Ingested matches queried value for {key}")

    assert_test(passed, log, pass_msg=f'All valid fields matched.', fail_msg=f'One or more fields do not match.')


def _lowercase(obj):
    """Make Multi-level dictionary lowercase, including keys and values.

    Parameters
    ----------
    obj:
        object to check, handles different object and makes sure they are
        cast to lowercase.

    Return
    ------
    a stringified, lowercased version of the object passed in.
    """
    if isinstance(obj, dict):
        return {k.lower(): _lowercase(v) for k, v in obj.items()}
    elif isinstance(obj, (list, set, tuple)):
        t = type(obj)
        return t(_lowercase(o) for o in obj)
    elif isinstance(obj, str):
        return obj.lower()
    else:
        return str(obj).lower()


def test_auth(log: Logger, query_interactions: QueryInteractions):
    """Tests that datawave's auths are working as expected"""
    test = Test(log, test_auth)
    query_params = QueryParams(query_name="test-query",
                               query=f"GENRES == 'Test'",
                               auths=None)

    with test.subtest("Test invalid auth"):
        query_params.auths = 'INVALID'
        try:
            args = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                                   auths=query_params.auths, filter=None, output=None)
            results = query_interactions.perform_query(args)
            for data in results['events']:
                log.debug(data)
            raise AssertionError(f'Expected error but got results')
        except RuntimeError:
            log.info('Got expected error.')

    with test.subtest("Test invalid auth with valid as well"):
        query_params.auths = 'INVALID,PUBLIC'
        try:
            args = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                               auths=query_params.auths, filter=None, output=None)
            results = query_interactions.perform_query(args)
            for data in results['events']:
                log.debug(data)
            raise AssertionError(f'Expected error but got results')
        except RuntimeError:
            log.info('Got expected error.')

    with test.subtest("Test PRIVATE auth"):
        query_params.auths = 'PRIVATE'
        expected = {'Lorem Ipsum: The Series', 'Galactic Explorers', 'Small Town Shenanigans'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test PRIVATE,PUBLIC auth"):
        query_params.auths = 'PRIVATE,PUBLIC'
        expected = {'Lorem Ipsum: The Series', 'City of Shadows', 'Small Town Shenanigans',
                    'Jungle Quest', 'Galactic Explorers', 'Whispers in the Dark', 'The Singles Show'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test FOO,BAR auth"):
        query_params.auths = 'FOO,BAR'
        expected = {'Whispers in the Dark', 'Chronicles of Tomorrow', 'Small Town Shenanigans'}
        execute_query(query_params, expected, query_interactions)

    assert test.passed


def test_operators(log: Logger, query_interactions: QueryInteractions):
    """Tests the arithmetic operators for datawave"""
    test = Test(log, test_operators)
    query_params = QueryParams(query_name="test-query",
                               query=None,
                               auths='FOO,BAR,PUBLIC,PRIVATE')

    with test.subtest("Test == Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME == 45"
        expected = {'Lorem Ipsum: The Series', 'Jungle Quest'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test != Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME == 45 && GENRES != 'Lorem'"
        expected = {'Jungle Quest'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test < Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME < 45"
        expected = {'Small Town Shenanigans', 'Pixel Pals', 'The Singles Show'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test <= Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME <= 45"
        expected = {'Lorem Ipsum: The Series', 'Jungle Quest', 'Small Town Shenanigans', 'Pixel Pals', 'The Singles Show'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test > Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME > 50"
        expected = {'Eternal Realms', 'Dynasty of Thrones', 'Chronicles of Tomorrow'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test >= Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME >= 50"
        expected = {'Galactic Explorers', 'Eternal Realms', 'Whispers in the Dark',
                    'Dynasty of Thrones', 'Chronicles of Tomorrow', 'Realm Guardians',
                    'City of Shadows'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test || Operator"):
        query_params.query = "GENRES == 'Test' && RUNTIME == 60 || RUNTIME == 45"
        expected = {'Dynasty of Thrones', 'Lorem Ipsum: The Series', 'Jungle Quest'}
        execute_query(query_params, expected, query_interactions)

    assert test.passed


def test_date_queries(log: Logger, query_interactions: QueryInteractions):
    """Tests date query options"""
    test = Test(log, test_date_queries)
    query_params = QueryParams(query_name="test-query",
                               query=None,
                               auths='FOO,BAR,PUBLIC,PRIVATE')

    with test.subtest("Test beforeDate"):
        query_params.query = "GENRES == 'Test' && filter:beforeDate(PREMIERED, '2023-10-01')"
        expected = {'Lorem Ipsum: The Series', 'Whispers in the Dark', 'Eternal Realms',
                    'Dynasty of Thrones', 'Realm Guardians', 'Small Town Shenanigans', 'The Singles Show'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test afterDate"):
        query_params.query = "GENRES == 'Test' && filter:afterDate(PREMIERED, '2024-01-01')"
        expected = {'Jungle Quest', 'Galactic Explorers'}
        execute_query(query_params, expected, query_interactions)

    with test.subtest("Test betweenDates"):
        query_params.query = "GENRES == 'Test' && filter:betweenDates(PREMIERED, '2023-10-01', '2024-01-01')"
        expected = {'Pixel Pals', 'City of Shadows', 'Chronicles of Tomorrow'}
        execute_query(query_params, expected, query_interactions)

    assert test.passed


def execute_query(query_params: QueryParams, expected: set, query_interactions: QueryInteractions):
    results = []
    sns = SimpleNamespace(query_name=query_params.query_name, query=query_params.query,
                          auths=query_params.auths, filter='NAME', output=None, decode_raw=False)
    results = query_interactions.perform_query(sns)['events']
    actual = {name for event in results for name in event.values()}
    if actual != expected:
        raise AssertionError(f'Expected {expected} but found {actual}')