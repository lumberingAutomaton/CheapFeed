# CheapFeed

A World of Warcraft: Forever addon for hunters. It adds a feed button that feeds your pet in one click, always using the food in your bags that gives the most happiness for the least value.

## Usage

The button appears whenever your pet is out. It shows the food it will use, and your pet's happiness under it (for example `925 / 1000`).

| Action | What it does |
|---|---|
| Left-click | Casts Feed Pet on the top food |
| Middle-click | Opens the food list |
| Right-click | Ignores the top food |
| Shift-left-drag | Moves the button |

You can also bind a key to it under **Key Bindings → AddOns → CheapFeed**.

The food list shows every food in your bags that your pet eats, best first. Untick a food to stop the button using it, for example buff food you want to keep for yourself; tick it to use it again.

## How it picks food

- **Which food your pet eats:** asked directly from the game, so it matches your pet's diet.
- **What a food is worth:** its Auctionator price if you have Auctionator, otherwise its vendor sell price. Food that can't be sold counts as free.
- **How much happiness it gives:** based on how far the food's level is below your pet's: the further below, the less it gives.
- **The choice:** when your pet is content or unhappy, the best value per happiness. When it's already happy, the cheapest food outright, since most of a feeding would be wasted.
- **Learning:** if the game refuses a food as too low-level, CheapFeed stops offering it at that pet level.

Forever doesn't let addons do maths with the pet's exact happiness, so the number on the button is for you to read; CheapFeed itself uses the happy, content and unhappy states.

## Commands

- `/cheapfeed ignored` lists ignored foods.
- `/cheapfeed unignore <number or name>` stops ignoring one.
- `/cheapfeed reset` clears ignored foods and learned refusals.
- `/cheapfeed center` moves the button back to the middle of the screen.

## Install

Copy or symlink this folder into `World of Warcraft/_forever_/Interface/AddOns/CheapFeed`, then restart the game. Auctionator is optional but recommended.

## Compatibility

Interface `16001` (WoW Forever). The happiness bands (350 per feeding for food under 10 levels below your pet, 170 for 10–19, 80 for 20–29) are the ones other Forever hunter addons use, matching the Vanilla-era table; they haven't been measured independently.
