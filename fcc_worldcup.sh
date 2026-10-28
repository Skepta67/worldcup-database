#!/usr/bin/env bash
# freeCodeCamp - World Cup Database (official v2.0.0 project)
# Self-contained, resumable setup for a fresh CodeRoad Codespaces project.
# Place next to games.csv, insert_data.sh, queries.sh and .freeCodeCamp/.
# Usage: bash fcc_worldcup.sh --run
#        bash fcc_worldcup.sh --status
#        bash fcc_worldcup.sh --verify
#        bash fcc_worldcup.sh --restart   # re-run all stages without deleting data

set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE="$ROOT/.fcc_worldcup.progress"
LOG="$ROOT/.fcc_worldcup.log"
BACKUP="$ROOT/.fcc_worldcup_backup"
ACTUAL="$ROOT/.fcc_worldcup_actual_output.txt"
APP_USER=${FCC_WORLDCUP_PG_USER:-freecodecamp}
CURRENT=0

say() { printf '%s\n' "$*"; }
fail() { say "ERROR (stage $CURRENT): $*" >&2; say "Log: $LOG" >&2; exit 1; }

usage() {
  say 'World Cup Database - automatic 5-stage runner, 11 official checks' \
    '  bash fcc_worldcup.sh --run        # auto-run and resume after a failure' \
    '  bash fcc_worldcup.sh --status     # show completed stage' \
    '  bash fcc_worldcup.sh --verify     # rerun queries and official checks' \
    '  bash fcc_worldcup.sh --restart    # redo stages; preserve databases/data' \
    '' \
    'Ctrl+C stops safely. Existing databases are never dropped or truncated.' \
    'Original insert_data.sh / queries.sh are backed up once before editing.'
}

require_environment() {
  command -v psql >/dev/null 2>&1 || fail 'psql is missing. Start the CodeRoad project environment.'
  [[ -f "$ROOT/games.csv" ]] || fail "Missing $ROOT/games.csv. Put this script in the World Cup tutorial project folder."
  [[ -f "$ROOT/expected_output.txt" ]] || fail "Missing $ROOT/expected_output.txt."
  [[ -d "$ROOT/.freeCodeCamp" ]] || fail 'Missing .freeCodeCamp/. Open/start the World Cup CodeRoad tutorial first.'
  psql --username="$APP_USER" --dbname=postgres -X -qAt \
    --set=ON_ERROR_STOP=1 --command 'SELECT 1' >> "$LOG" 2>&1 ||
    fail "Cannot connect to PostgreSQL as $APP_USER. Start PostgreSQL/CodeRoad and retry."
}

query() {
  local database=$1 sql=$2
  psql -X --username="$APP_USER" --dbname="$database" -qAt \
    --set=ON_ERROR_STOP=1 --command "$sql" 2>> "$LOG"
}

execute_sql() {
  local database=$1 sql=$2
  psql -X --username="$APP_USER" --dbname="$database" \
    --set=ON_ERROR_STOP=1 --command "$sql" >> "$LOG" 2>&1 ||
    fail "SQL failed against $database. Check $LOG."
}

stage_database() {
  say '[1/5] Checking worldcup database...'
  if [[ $(query postgres "SELECT COUNT(*) FROM pg_database WHERE datname='worldcup';") == 0 ]]; then
    execute_sql postgres 'CREATE DATABASE worldcup;'
    say '  Created database worldcup.'
  else
    say '  Reusing existing worldcup database.'
  fi
}

stage_schema() {
  say '[2/5] Creating required tables, keys, and NOT NULL columns...'
  execute_sql worldcup '
CREATE TABLE IF NOT EXISTS teams (
  team_id SERIAL PRIMARY KEY,
  name VARCHAR(60) UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS games (
  game_id SERIAL PRIMARY KEY,
  year INTEGER NOT NULL,
  round VARCHAR(60) NOT NULL,
  winner_id INTEGER NOT NULL REFERENCES teams(team_id),
  opponent_id INTEGER NOT NULL REFERENCES teams(team_id),
  winner_goals INTEGER NOT NULL,
  opponent_goals INTEGER NOT NULL
);'
  say '  Schema created or already present.'
}

backup_once() {
  local name=$1
  [[ ! -L "$ROOT/$name" ]] || fail "Will not overwrite symlink $name."
  mkdir -p "$BACKUP"
  if [[ -f "$ROOT/$name" && ! -f "$BACKUP/$name.original" ]]; then
    cp -p -- "$ROOT/$name" "$BACKUP/$name.original" || fail "Cannot back up $name."
    say "  Saved original $name in .fcc_worldcup_backup/."
  fi
}

stage_scripts() {
  say '[3/5] Completing insert_data.sh and queries.sh...'
  backup_once insert_data.sh
  backup_once queries.sh

  # Keep the official four-line PSQL selection at the start of insert_data.sh.
  # The CSV is turned into one bulk PostgreSQL call (the tests allow 20 seconds).
  cat > "$ROOT/insert_data.sh" <<'INSERT_SCRIPT'
#! /bin/bash

if [[ $1 == "test" ]]
then
  PSQL="psql --username=postgres --dbname=worldcuptest -t --no-align -c"
else
  PSQL="psql --username=freecodecamp --dbname=worldcup -t --no-align -c"
fi

# Do not change code above this line. Use the PSQL variable above to query your database.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
[[ -r games.csv ]] || { printf 'games.csv is missing\n' >&2; exit 1; }

sql_values=''
count=0
while IFS=',' read -r YEAR ROUND WINNER OPPONENT WINNER_GOALS OPPONENT_GOALS || [[ -n "${YEAR:-}" ]]; do
  [[ $YEAR == 'year' || -z $YEAR ]] && continue
  [[ $YEAR =~ ^[0-9]{4}$ && $WINNER_GOALS =~ ^[0-9]+$ && $OPPONENT_GOALS =~ ^[0-9]+$ ]] || {
    printf 'Malformed CSV row %d\n' "$((count + 2))" >&2; exit 1;
  }
  ROUND=${ROUND//\'/\'\'}
  WINNER=${WINNER//\'/\'\'}
  OPPONENT=${OPPONENT//\'/\'\'}
  sql_values+="($YEAR,'$ROUND','$WINNER','$OPPONENT',$WINNER_GOALS,$OPPONENT_GOALS),"
  count=$((count + 1))
done < games.csv

(( count > 0 )) || { printf 'games.csv contains no games\n' >&2; exit 1; }
sql_values=${sql_values%,}

# One SQL invocation for all 32 games. Re-running does not duplicate imported rows.
$PSQL "
CREATE TEMP TABLE wc_import (
  year INTEGER, round VARCHAR(60), winner VARCHAR(60), opponent VARCHAR(60),
  winner_goals INTEGER, opponent_goals INTEGER
);
INSERT INTO wc_import VALUES $sql_values;
INSERT INTO teams (name)
SELECT name FROM (
  SELECT winner AS name FROM wc_import UNION SELECT opponent AS name FROM wc_import
) AS distinct_teams
ON CONFLICT (name) DO NOTHING;
INSERT INTO games (year, round, winner_id, opponent_id, winner_goals, opponent_goals)
SELECT i.year, i.round, w.team_id, o.team_id, i.winner_goals, i.opponent_goals
FROM wc_import AS i
JOIN teams AS w ON w.name = i.winner
JOIN teams AS o ON o.name = i.opponent
WHERE NOT EXISTS (
  SELECT 1 FROM games AS g
  WHERE g.year = i.year AND g.round = i.round
    AND g.winner_id = w.team_id AND g.opponent_id = o.team_id
    AND g.winner_goals = i.winner_goals AND g.opponent_goals = i.opponent_goals
);
" >/dev/null
printf 'Imported %d CSV games into %s\n' "$count" "${1:-worldcup}"
INSERT_SCRIPT

  cat > "$ROOT/queries.sh" <<'QUERIES_SCRIPT'
#! /bin/bash

PSQL="psql --username=freecodecamp --dbname=worldcup --no-align --tuples-only -c"

# Do not change code above this line. Use the PSQL variable above to query your database.

echo -e "\nTotal number of goals in all games from winning teams:"
echo "$($PSQL "SELECT SUM(winner_goals) FROM games")"

echo -e "\nTotal number of goals in all games from both teams combined:"
echo "$($PSQL "SELECT SUM(winner_goals + opponent_goals) FROM games")"

echo -e "\nAverage number of goals in all games from the winning teams:"
echo "$($PSQL "SELECT AVG(winner_goals) FROM games")"

echo -e "\nAverage number of goals in all games from the winning teams rounded to two decimal places:"
echo "$($PSQL "SELECT ROUND(AVG(winner_goals), 2) FROM games")"

echo -e "\nAverage number of goals in all games from both teams:"
echo "$($PSQL "SELECT AVG(winner_goals + opponent_goals) FROM games")"

echo -e "\nMost goals scored in a single game by one team:"
echo "$($PSQL "SELECT MAX(GREATEST(winner_goals, opponent_goals)) FROM games")"

echo -e "\nNumber of games where the winning team scored more than two goals:"
echo "$($PSQL "SELECT COUNT(*) FROM games WHERE winner_goals > 2")"

echo -e "\nWinner of the 2018 tournament team name:"
echo "$($PSQL "SELECT name FROM teams JOIN games ON teams.team_id = games.winner_id WHERE year = 2018 AND round = 'Final'")"

echo -e "\nList of teams who played in the 2014 'Eighth-Final' round:"
echo "$($PSQL "SELECT name FROM teams WHERE team_id IN (SELECT winner_id FROM games WHERE year = 2014 AND round = 'Eighth-Final' UNION SELECT opponent_id FROM games WHERE year = 2014 AND round = 'Eighth-Final') ORDER BY name")"

echo -e "\nList of unique winning team names in the whole data set:"
echo "$($PSQL "SELECT DISTINCT name FROM teams JOIN games ON teams.team_id = games.winner_id ORDER BY name")"

echo -e "\nYear and team name of all the champions:"
echo "$($PSQL "SELECT year, name FROM games JOIN teams ON games.winner_id = teams.team_id WHERE round = 'Final' ORDER BY year")"

echo -e "\nList of teams that start with 'Co':"
echo "$($PSQL "SELECT name FROM teams WHERE name LIKE 'Co%' ORDER BY name")"
QUERIES_SCRIPT

  chmod +x "$ROOT/insert_data.sh" "$ROOT/queries.sh"
  bash -n "$ROOT/insert_data.sh" || fail 'Syntax error in generated insert_data.sh.'
  bash -n "$ROOT/queries.sh" || fail 'Syntax error in generated queries.sh.'
  say '  Created two executable scripts.'
}

stage_import() {
  say '[4/5] Importing all matches and teams from games.csv...'
  bash "$ROOT/insert_data.sh" >> "$LOG" 2>&1 || fail "insert_data.sh failed. See $LOG."
  local teams games
  teams=$(query worldcup 'SELECT COUNT(*) FROM teams;') || fail 'Cannot count teams.'
  games=$(query worldcup 'SELECT COUNT(*) FROM games;') || fail 'Cannot count games.'
  say "  Database rows: $teams teams, $games games (expected 24 and 32)."
  [[ $teams == 24 && $games == 32 ]] ||
    fail 'Unexpected counts. An existing worldcup database may contain extra data; no rows were deleted.'
}

verify_all() {
  say '[5/5] Checking generated output against expected_output.txt...'
  bash "$ROOT/queries.sh" > "$ACTUAL" 2>> "$LOG" || fail "queries.sh failed. See $LOG."
  if ! diff -u <(tr -d '[:space:]' < "$ROOT/expected_output.txt") \
       <(tr -d '[:space:]' < "$ACTUAL") >> "$LOG" 2>&1; then
    fail "Query output differs from expected_output.txt. Compare $ACTUAL with expected_output.txt."
  fi
  say '  All 12 query outputs match.'

  if [[ ! -f "$ROOT/.freeCodeCamp/test/1.1.test.js" ]]; then
    say '  Official test not present in .freeCodeCamp; skipping official Mocha run.'
    return
  fi
  if [[ ! -x "$ROOT/.freeCodeCamp/node_modules/.bin/mocha" ]]; then
    say '  Installing official test dependencies (first time only)...'
    (cd "$ROOT/.freeCodeCamp" && npm install --no-audit --no-fund) >> "$LOG" 2>&1 ||
      fail 'Could not install official test dependencies.'
  fi
  say '  Running all 11 official freeCodeCamp checks...'
  (cd "$ROOT/.freeCodeCamp" && npm run programmatic-test) >> "$LOG" 2>&1 ||
    fail "Official tests failed. Inspect $LOG and retry --run after a fix."
  say '  All 11 official checks passed.'
}

show_status() {
  local last=0
  [[ -f "$STATE" ]] && read -r last < "$STATE"
  [[ $last =~ ^[0-5]$ ]] || last=0
  say "World Cup runner: stage $last/5 saved."
  if (( last == 5 )); then
    say 'Last run passed every available verification.'
  else
    say "Resume with: bash fcc_worldcup.sh --run"
  fi
}

run_all() {
  cd -- "$ROOT"
  : >> "$LOG"
  CURRENT=0
  require_environment
  local saved=0
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || fail 'Invalid progress file; inspect .fcc_worldcup.progress.'
  if (( saved == 5 )); then
    say 'Already completed: 5/5. Use --verify to recheck the official tests.'
    return
  fi
  local stage
  for stage in 1 2 3 4 5; do
    (( stage > saved )) || continue
    CURRENT=$stage
    case "$stage" in
      1) stage_database ;;
      2) stage_schema ;;
      3) stage_scripts ;;
      4) stage_import ;;
      5) verify_all ;;
    esac
    printf '%s\n' "$stage" > "$STATE"
    saved=$stage
    say "  ✓ Stage $stage/5 complete."
  done
  say 'DONE! World Cup Database completed and official checks passed (when installed).'
  say 'Review your CodeRoad tutorial pane and click Run if it has not refreshed.'
}

case "${1:---run}" in
  --run) run_all ;;
  --status) show_status ;;
  --verify) cd -- "$ROOT"; : >> "$LOG"; CURRENT=5; require_environment; verify_all ;;
  --restart)
    # Only reset this runner's checkpoint. Never delete the database or CSV.
    printf '0\n' > "$STATE"
    run_all
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
