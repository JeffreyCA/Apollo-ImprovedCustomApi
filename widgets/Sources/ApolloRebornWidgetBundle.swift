import WidgetKit
import SwiftUI

@main
struct ApolloRebornWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShowerthoughtsWidget()
        JokesWidget()
        SinglePostWidget()
        FeedWidget()
        PhotoWidget()
        ShortcutsWidget()
        ApolloQuickActionsWidget()
        CalendarWidget()
        HeadlineWidget()
    }
}

struct HeadlineWidget: Widget {
    let kind = "HeadlineWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: HeadlineConfigurationIntent.self,
                            provider: HeadlineProvider()) { entry in
            HeadlineWidgetView(entry: entry)
        }
        .configurationDisplayName("Headline")
        .description("The top headline from a subreddit you choose, on your Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct CalendarWidget: Widget {
    let kind = "CalendarWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: CalendarConfigurationIntent.self,
                            provider: CalendarProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("Calendar")
        .description("One photo a day from a subreddit, with the date overlaid. Locked daily — it won't change until tomorrow.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ApolloQuickActionsWidget: Widget {
    let kind = "ApolloQuickActionsWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ApolloQuickActionsProvider()) { entry in
            ApolloQuickActionsWidgetView(entry: entry)
        }
        .configurationDisplayName("Apollo Actions")
        .description("Quick actions for search, home, popular, all posts, and inbox.")
        .supportedFamilies([.systemMedium])
    }
}

struct ShortcutsWidget: Widget {
    let kind = "ShortcutsWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: ShortcutsConfigurationIntent.self,
                            provider: ShortcutsProvider()) { entry in
            ShortcutsWidgetView(entry: entry)
        }
        .configurationDisplayName("Shortcuts")
        .description("Quick links to your favorite subreddits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShowerthoughtsWidget: Widget {
    let kind = "ShowerthoughtsWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: ShowerthoughtsConfigurationIntent.self,
                            provider: ShowerthoughtsProvider()) { entry in
            ShowerthoughtsWidgetView(entry: entry)
        }
        .configurationDisplayName("Showerthoughts")
        .description("Top posts from r/showerthoughts.")
        // accessoryCircular dropped — a circular lock-screen slot can only show
        // an icon, no thought text, so it added nothing.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct JokesWidget: Widget {
    let kind = "JokesWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: JokesConfigurationIntent.self,
                            provider: JokesProvider()) { entry in
            JokesWidgetView(entry: entry)
        }
        .configurationDisplayName("Jokes")
        .description("A joke from r/Jokes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct SinglePostWidget: Widget {
    let kind = "SinglePostWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: PostConfigurationIntent.self,
                            provider: SinglePostProvider()) { entry in
            SinglePostWidgetView(entry: entry)
        }
        .configurationDisplayName("Post")
        .description("The top post from a subreddit you choose.")
        // Home-screen only. Lock-screen content comes from the zero-config
        // Showerthoughts widget, so the lock screen stays option-free.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FeedWidget: Widget {
    let kind = "FeedWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: SubredditConfigurationIntent.self,
                            provider: FeedProvider()) { entry in
            FeedWidgetView(entry: entry)
        }
        .configurationDisplayName("Feed")
        .description("Top posts from a subreddit you choose.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PhotoWidget: Widget {
    let kind = "PhotoWidget"
    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind,
                            intent: PhotoConfigurationIntent.self,
                            provider: PhotoProvider()) { entry in
            PhotoWidgetView(entry: entry)
        }
        .configurationDisplayName("Photo")
        .description("The top image from a subreddit you choose. Toggle the title, subreddit and stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
