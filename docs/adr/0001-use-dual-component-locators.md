# Use dual component locators

A component is identified both as a logical occurrence (`design`, `refdes`, and hierarchical `path`) and as a graphical page instance (`design`, `page`, and `object_id`). Property operations use the occurrence identity, while future page-graphical operations use the page-instance identity; keeping both prevents operations from silently targeting the wrong Capture object layer and lets component queries share one result contract regardless of how a component was found.
