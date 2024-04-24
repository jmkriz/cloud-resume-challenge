def get_visitor_count(db_table):
    count = db_table.get_item(Key={'id': 'visitors'})['Item']['visitor_count']
    return int(count)

def increment_visitor_count(db_table):
    update_expression = 'SET visitor_count = visitor_count + :one'
    eav = {':one': 1}
    response = db_table.update_item(TableName='resume', Key={'id': 'visitors'},
                                    UpdateExpression=update_expression,
                                    ExpressionAttributeValues=eav)
    return response['ResponseMetadata']['HTTPStatusCode']
