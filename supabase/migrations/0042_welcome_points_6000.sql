-- New players were getting 12,000 welcome points (tuned via the admin panel
-- at some point after the 10,000 default was set in 0028) -- drop it to 6,000.

UPDATE settings SET value = '6000'::jsonb WHERE key = 'welcome_points';
