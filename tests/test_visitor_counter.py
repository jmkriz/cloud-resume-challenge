import boto3
import moto
import os
import pytest

from contextlib import contextmanager
from src import visitor_counter

# Fake AWS credentials, to ensure tests don't accidentally affect prod
@pytest.fixture
def dummy_credentials():
    os.environ["AWS_ACCESS_KEY_ID"] = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SECURITY_TOKEN"] = 'testing'
    os.environ["AWS_SESSION_TOKEN"] = 'testing'
    os.environ["AWS_DEFAULT_REGION"] = 'us-east-1'

@pytest.fixture
def dummy_dynamodb_client(dummy_credentials):
    with moto.mock_dynamodb():
        client = boto3.client('dynamodb')
        yield client

@contextmanager
def dummy_table(dummy_dynamodb_client, **kwargs):
    table_key = kwargs['table_key'] if 'table_key' in kwargs else 'id'
    table_name = kwargs['table_name'] if 'table_name' in kwargs else 'resume'
    key_value = kwargs['key_value'] if 'key_value' in kwargs else 'visitors'
    count_name = kwargs['count_name'] if 'count_name' in kwargs else 'visitor_count'
    count_value = kwargs['count_value'] if 'count_value' in kwargs else 0

    dummy_dynamodb_client.create_table(
        AttributeDefinitions = [
            {'AttributeName': table_key, 'AttributeType': 'S'}
        ],
        TableName = table_name,
        KeySchema = [
            {'AttributeName': table_key, 'KeyType': 'HASH'}
        ],
        BillingMode = 'PAY_PER_REQUEST'
    )
    table = boto3.resource('dynamodb').Table(table_name)
    table.put_item(Item={table_key: key_value, count_name: count_value})
    yield

def test_zero(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] == 0
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 200
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] == 1

def test_fortytwo(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client, count_value = 42):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] == 42
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 200
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] == 43

def test_no_table(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client, table_name = 'test'):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['statusCode'] == 400
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 400

def test_wrong_key(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client, table_key = 'test'):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['statusCode'] == 400
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 400

def test_wrong_key_value(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client, key_value = 'test'):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] is None
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 400

def test_wrong_count_column_name(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client, count_name = 'test'):
        assert visitor_counter.lambda_handler({'httpMethod': 'GET'}, None)['body'] is None
        assert visitor_counter.lambda_handler({'httpMethod': 'POST'}, None)['statusCode'] == 400

def test_method_not_allowed(dummy_dynamodb_client):
    with dummy_table(dummy_dynamodb_client):
        assert visitor_counter.lambda_handler({'httpMethod': 'DELETE'}, None)['statusCode'] == 405
