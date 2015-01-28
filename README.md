# flow2

A simple blogging / linklogging tool for communities. Used to run http://rubyflow.com/

## Features:

* Admin user can delete any comment or edit/delete any post
* Optimized for running on Heroku

## Dependencies

You need to have these things:

* Postgres (9.3 fine for now)
* an account at Twitter or GitHub to create an 'app' for OAuth usage there
* Redis (you *can* run without it but you'll get no rate limiting or caching)

In production, use Heroku plus their Postgres service and the Redis Cloud service. You can run a simple flow2 install entirely for free this way but then have the option to scale up in future.

## Development / local use

Setting up .env is the longest piece of the puzzle, but once it's set up, you're good. First, you need to specify your app's root URL:

    BASE_URL=http://localhost:5000

And give your site a name and description:

    SITE_NAME=RubyFlow
    SITE_DESCRIPTION=The Ruby and Rails community linklog

You'll need to specify your local Postgres' database URL like so:

    DATABASE_URL=postgres://flow2:flow2@localhost/flow2

If your Redis instance is on localhost at the default port, you don't need to do anything else, otherwise .env will require an entry like this:

    REDIS_URL=redis://localhost:6379

You would also do well to have an S3 bucket set up (for user avatars). It's not a strict requirement though. If you do set it up, you'll need these entries in .env:

    AWS_KEY=... etc.
    AWS_SECRET=... etc.
    AWS_BUCKET=your-bucket-name-here

You'll also need to create an 'application' for OAuth / authentication purposes over at either GitHub or Twitter (for now) then enter the keys into .env like so:

    GITHUB_KEY=...
    GITHUB_SECRET=...
    AUTH_PROVIDER=GitHub

And to finally run the app:

    foreman start

## Deployment to production

flow2 has been optimized to deploy well on Heroku. You can deploy it elsewhere, but you'll need to figure out the details.

For Heroku, you'll need to repeat a lot of the .env process from the development setup (above) but using `heroku config:set` instead.

Things to consider:

* Use Heroku's Postgres service and they'll populate `DATABASE_URL` for you, so that's easy.

* Use the Redis Cloud add on and you'll get a 25MB Redis instance for free! It'll auto-populate the `REDISCLOUD_URL` variable too, which this apps detects automatically.

* You'll need a separate OAuth setup (with key and secret) from GitHub or Twitter, etc.

### The actual process

    git clone git@github.com:peterc/flow2.git yourflow
    cd yourflow
    heroku apps:create yourflow
    heroku addons:add heroku-postgresql:hobby-dev
    heroku addons:add rediscloud
    heroku config:set RACK_ENV=production
    heroku config:set AUTH_PROVIDER=GitHub GITHUB_KEY=... GITHUB_SECRET=...
    heroku config:set BASE_URL=http://yourflow.herokuapp.com/

Eventually, you can just do this:

    git push heroku master

## TODOs

* Search
* Have a 'moderator' role
* A proper configuration system for customizing without touching code
* Good caching - it's just RSS and front page for non logged in users for now
