from splink.internals.blocking_rule_creator import blocking_rule_to_obj

d = {'blocking_rule': 'l."raw_nome" = r."raw_nome"', 'sql_dialect': 'duckdb', 'arrays_to_explode': None}
obj = blocking_rule_to_obj(d)
print('obj:', obj)
print('type:', type(obj))
print('dir:', [a for a in dir(obj) if not a.startswith('_')])

from splink.backends.duckdb import DuckDBAPI
db_api = DuckDBAPI()
try:
    sql = obj.get_blocking_rule(db_api.sql_dialect)
    print('sql:', sql)
except Exception as e:
    print('get_blocking_rule error:', e)

if hasattr(obj, 'blocking_rule'):
    print('blocking_rule attr:', obj.blocking_rule)
