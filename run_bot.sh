#!/bin/bash

# Replace 'your_command' with the command you want to keep running
COMMAND="ruby bot.rb"

while true; do
  echo "Starting process: $COMMAND"
  $COMMAND
  echo "Process terminated. Restarting in 10 seconds..."
  sleep 10
done
 
