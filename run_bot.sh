#!/bin/bash

# Replace 'ruby bot.rb' with your command
COMMAND="ruby bot.rb"
UPDATED_COMMAND="ruby bot.rb 'my code has been updated!'"
GIT_CHECK_INTERVAL=1800  # 30 minutes in seconds
RESTART_FLAG=false

# Track the last git pull time
LAST_GIT_PULL=$(date +%s)

while true; do
  # Check if it's time to run git pull
  CURRENT_TIME=$(date +%s)
  TIME_DIFF=$((CURRENT_TIME - LAST_GIT_PULL))
  
  if [ "$TIME_DIFF" -ge "$GIT_CHECK_INTERVAL" ]; then
    echo "Checking for updates with git pull..."
    LAST_GIT_PULL=$CURRENT_TIME
    OUTPUT=$(git pull)
    
    # If there are changes, kill the running process and restart
    if [[ "$OUTPUT" != *"Already up to date."* ]]; then
      echo "Updates found! Restarting process with updated code."
      pkill -f "$COMMAND"  # Kill the running process
      RESTART_FLAG=true
    fi
  fi

  # Restart process if needed or start a new one
  if [ "$RESTART_FLAG" = true ]; then
    echo "Starting process with updated code: $UPDATED_COMMAND"
    $UPDATED_COMMAND
    RESTART_FLAG=false
  else
    echo "Starting process: $COMMAND"
    $COMMAND
  fi

  echo "Process terminated. Restarting in 10 seconds..."
  sleep 10
done

