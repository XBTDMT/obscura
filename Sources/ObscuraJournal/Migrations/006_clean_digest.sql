-- The clean picture always matches the covered flags (fail-open #4, G-28): each entry row carries the SHA-256 of the
-- clean file it was committed with, written in the same transaction as the flags, the style and the revision. A read
-- whose bytes do not match (a crash between the file and the row, a file changed behind the store) or a row without a
-- digest (every entry from before this migration) is refused, and the engine renders that entry's clean picture again
-- from its original and its flags. The digest is of a whole image file, never of recognized text.
ALTER TABLE entries ADD COLUMN clean_sha256 TEXT;
