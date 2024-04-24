def get_visitor_count(db_table):
    response =  db_table.get_item(Key={'id': 'visitors'})
    return response

def increment_visitor_count(db_table):
    update_expression = 'SET visitor_count = visitor_count + :one'
    eav = {':one': 1}
    response = db_table.update_item(Key={'id': 'visitors'},
                                    UpdateExpression=update_expression,
                                    ExpressionAttributeValues=eav)
    return response
