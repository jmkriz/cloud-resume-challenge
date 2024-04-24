import boto3
import moto
import pytest

from src import visitor_counter

@pytest.fixture
def dummy_table():
    with moto.mock_dynamodb():
        client = boto3.client("dynamodb")
        client.create_table(
            AttributeDefinitions = [
                {"AttributeName": "id", "AttributeType": "S"}
            ],
            TableName = "resume",
            KeySchema = [
                {"AttributeName": "id", "KeyType": "HASH"}
            ],
            BillingMode="PAY_PER_REQUEST"
        )

        yield "resume"

@pytest.fixture
def zero_table(dummy_table):
    table = boto3.resource("dynamodb").Table(dummy_table)
    table.put_item(Item={"id": "visitors", "visitor_count": 0})
    yield table

@pytest.fixture
def fortytwo_table(dummy_table):
    table = boto3.resource("dynamodb").Table(dummy_table)
    table.put_item(Item={"id": "visitors", "visitor_count": 42})
    yield table

def test_zero(zero_table):
    assert int(visitor_counter.get_visitor_count(zero_table)['Item']['visitor_count']) == 0
    visitor_counter.increment_visitor_count(zero_table)
    assert int(visitor_counter.get_visitor_count(zero_table)['Item']['visitor_count']) == 1

def test_fortytwo(fortytwo_table):
    assert int(visitor_counter.get_visitor_count(fortytwo_table)['Item']['visitor_count']) == 42
    visitor_counter.increment_visitor_count(fortytwo_table)
    assert int(visitor_counter.get_visitor_count(fortytwo_table)['Item']['visitor_count']) == 43
