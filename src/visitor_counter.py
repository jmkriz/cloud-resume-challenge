import boto3
from botocore.exceptions import ClientError

def lambda_handler(event, context):
    dynamodb = boto3.resource('dynamodb')
    table = dynamodb.Table('resume')
    if event["httpMethod"] == 'GET':
        response = get_visitor_count(table)
        return {
            'statusCode': response['ResponseMetadata']['HTTPStatusCode'],
            'body': response['Item']['visitor_count'] if 'Item' in response and 'visitor_count' in response['Item'] else None
        }
    if event["httpMethod"] == 'POST':
        response = increment_visitor_count(table)
        return {
            'statusCode': response['ResponseMetadata']['HTTPStatusCode']
        }
    # 405: Method Not Allowed
    return {
        'statusCode': 405
    }

def get_visitor_count(db_table):
    try:
        response =  db_table.get_item(Key={'id': 'visitors'})
        return response
    except ClientError:
        return {'ResponseMetadata': {'HTTPStatusCode': 400}}

def increment_visitor_count(db_table):
    update_expression = 'SET visitor_count = visitor_count + :one'
    eav = {':one': 1}
    try:
        response = db_table.update_item(Key={'id': 'visitors'},
                                        UpdateExpression=update_expression,
                                        ExpressionAttributeValues=eav)
        return response
    except ClientError:
        return {'ResponseMetadata': {'HTTPStatusCode': 400}}
