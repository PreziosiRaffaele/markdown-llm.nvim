# PromptBook
- Each new buffer chat need to have a setup defined.
- When a new chat is created the setup is a deep clone of the one defined in the preset (the preset configuration that you select when you create a new chat can have a setup defined) or if missing of the default setup. 
- It is possible to change the setup of a conversation buffer with a specific command and chose a different one from a list.

- It is possible to adjust manually the setup related to a conversation buffer with a new command that opens a new buffer with the lua configuration. Saving this buffer will update the setup on the relative conversation buffer.

- It is possible to update the default setup but this will impact only new chats.

- rename active_setup_name with default_setup_name
- validate if the default_setup_name is present


