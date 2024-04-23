def get_visitor_count(db_table):
    count = db_table.get_item(Key={'id': 'visitors'})['Item']['visitor_count']
    return int(count)
