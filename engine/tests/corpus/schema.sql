CREATE TABLE permits (
    id INTEGER PRIMARY KEY,
    applicant TEXT NOT NULL,
    issued_on DATE,
    category TEXT
);
CREATE INDEX permits_issued ON permits(issued_on);
