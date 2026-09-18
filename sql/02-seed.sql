-- Two tenants with the same-shaped data. The tests assert that each one sees
-- exactly its own rows, so the seed deliberately gives them equal counts:
-- a test that passes because one side is empty proves nothing.
INSERT INTO tenants (id, name) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Acme'),
    ('22222222-2222-2222-2222-222222222222', 'Globex');

INSERT INTO documents (tenant_id, title, body) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Acme Q3 revenue',   'acme confidential'),
    ('11111111-1111-1111-1111-111111111111', 'Acme staff list',   'acme confidential'),
    ('22222222-2222-2222-2222-222222222222', 'Globex Q3 revenue', 'globex confidential'),
    ('22222222-2222-2222-2222-222222222222', 'Globex staff list', 'globex confidential');
