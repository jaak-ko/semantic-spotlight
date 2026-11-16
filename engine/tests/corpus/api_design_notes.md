# REST API design

Use plural nouns for resources, return 201 with a Location header on create, and use
cursor pagination for lists. Errors follow RFC 9457 problem+json. Version in the path (/v1).
