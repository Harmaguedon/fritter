import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:dart_twitter_api/src/utils/date_utils.dart';
import 'package:dart_twitter_api/twitter_api.dart';
import 'package:faker/faker.dart';
import 'package:ffcache/ffcache.dart';
import 'package:fritter/utils/cache.dart';
import 'package:fritter/utils/iterables.dart';
import 'package:http/http.dart' as http;
import 'package:quiver/iterables.dart';

const Duration _defaultTimeout = Duration(seconds: 10);
const String _bearerToken = 'Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';

class _FritterTwitterClient extends TwitterClient {
  _FritterTwitterClient() : super(
    consumerKey: '',
    consumerSecret: '',
    token: '',
    secret: ''
  );

  static String? _token;
  static int _expiresAt = -1;
  static int _tokenLimit = -1;
  static int _tokenRemaining = -1;

  @override
  Future<http.Response> get(Uri uri, {Map<String, String>? headers, Duration? timeout}) {
    return fetch(uri, headers: headers)
        .timeout(timeout ?? _defaultTimeout)
        .then((response) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      } else {
        return Future.error(response);
      }
    });
  }

  static Future<String> getToken() async {
    if (_token != null) {
      // If we don't have an expiry or limit, it's probably because we haven't made a request yet, so assume they're OK
      if (_expiresAt == -1 && _tokenLimit == -1 && _tokenRemaining == -1) {
        // TODO: Null safety with concurrent threads
        return _token!;
      }

      // Check if the token we have hasn't expired yet
      if (DateTime.now().millisecondsSinceEpoch < _expiresAt) {
        // Check if the token we have still has usages remaining
        if (_tokenRemaining < _tokenLimit) {
          // TODO: Null safety with concurrent threads
          return _token!;
        }
      }
    }

    // Otherwise, fetch a new token
    _token = null;
    _tokenLimit = -1;
    _tokenRemaining = -1;
    _expiresAt = -1;

    log('Refreshing the Twitter token');

    var response = await http.post(Uri.parse('https://api.twitter.com/1.1/guest/activate.json'), headers: {
      'authorization': _bearerToken,
    });

    if (response.statusCode == 200) {
      var result = jsonDecode(response.body);
      if (result.containsKey('guest_token')) {
        _token = result['guest_token'];

        return _token!;
      }
    }

    var message = 'Unable to refresh the token. The response (${response.statusCode}) from Twitter was: ' + response.body;
    log(message);
    throw new Exception(message);
  }

  static Future<http.Response> fetch(Uri uri, {Map<String, String>? headers}) async {
    log('Fetching $uri');

    var response = await http.get(uri, headers: {
      ...?headers,
      'authorization': _bearerToken,
      'x-guest-token': await getToken(),
      'x-twitter-active-user': 'yes',
      'user-agent': faker.internet.userAgent()
    });

    var headerRateLimitReset = response.headers['x-rate-limit-reset'];
    var headerRateLimitRemaining = response.headers['x-rate-limit-remaining'];
    var headerRateLimitLimit = response.headers['x-rate-limit-limit'];

    if (headerRateLimitReset == null || headerRateLimitRemaining == null || headerRateLimitLimit == null) {
      // If the rate limit headers are missing, the endpoint probably doesn't send them back
      return response;
    }

    // Update our token's rate limit counters
    _expiresAt = int.parse(headerRateLimitReset) * 1000;
    _tokenRemaining = int.parse(headerRateLimitRemaining);
    _tokenLimit = int.parse(headerRateLimitLimit);

    return response;
  }

}

class Twitter {
  static TwitterApi _twitterApi = TwitterApi(client: _FritterTwitterClient());

  static FFCache _cache = FFCache();

  static Map<String, String> defaultParams = {
    'include_profile_interstitial_type': '0',
    'include_blocking': '0',
    'include_blocked_by': '0',
    'include_followed_by': '0',
    'include_mute_edge': '0',
    'include_can_dm': '0',
    'include_can_media_tag': '1',
    'skip_status': '1',
    'cards_platform': 'Web-12',
    'include_cards': '1',
    'include_composer_source': 'false',
    'include_ext_alt_text': 'true',
    'include_reply_count': '1',
    'tweet_mode': 'extended',
    'include_entities': 'true',
    'include_user_entities': 'true',
    'include_ext_media_color': 'false',
    'include_ext_media_availability': 'true',
    'send_error_codes': 'true',
    'simple_quoted_tweet': 'true',
    'ext': 'mediaStats',
    'include_quote_count': 'true'
  };

  static Future<User> getProfile(String username) async {
    var uri = Uri.https('twitter.com', '/i/api/graphql/Vf8si2dfZ1zmah8ePYPjDQ/UserByScreenNameWithoutResults', {
      'variables': jsonEncode({
        'screen_name': username,
        'withHighlightedLabel': true
      })
    });

    var response = await _twitterApi.client.get(uri);
    var content = jsonDecode(response.body);

    return User.fromJson({
      ...content['data']['user']['legacy'],
      'id_str': content['data']['user']['rest_id']
    });
  }

  static List<TweetChain> createTweetChains(dynamic globalTweets, dynamic globalUsers, dynamic instructions) {
    List<TweetChain> replies = [];

    for (var entry in instructions[0]['addEntries']['entries']) {
      var entryId = entry['entryId'] as String;
      if (entryId.startsWith('tweet-')) {
        // Ignore it, as it's just the main tweet, which we already have
      }

      if (entryId.startsWith('cursor-bottom') || entryId.startsWith('cursor-showMore')) {
        // TODO: Use as the "next page" cursor
      }

      if (entryId.startsWith('conversationThread')) {
        List<TweetWithCard> tweets = [];

        for (var item in entry['content']['timelineModule']['items']) {
          if (item['entryId'].startsWith('tweet')) {
            var content = item['item']['content'] as Map<String, dynamic>;
            if (content.containsKey('tombstone')) {
              tweets.add(TweetWithCard.tombstone(content['tombstone']['tombstoneInfo']));
            } else {
              tweets.add(TweetWithCard.fromCardJson(globalTweets, globalUsers, globalTweets[content['tweet']['id']]));
            }
          }
        }

        // TODO: There must be a better way of getting the conversation ID
        replies.add(TweetChain(id: entryId.replaceFirst('conversationThread-', ''), tweets: tweets, isPinned: false));
      }
    }

    return replies;
  }

  static Future<TweetStatus> getTweet(String id) async {
    var response = await _twitterApi.client.get(
        Uri.https('api.twitter.com', '/2/timeline/conversation/$id.json', {
          ...defaultParams,
          'include_tweet_replies': '1',
          'include_want_retweets': '1',
        })
    );

    var result = json.decode(response.body);

    var globalTweets = result['globalObjects']['tweets'];
    var instructions = result['timeline']['instructions'];
    var globalUsers = result['globalObjects']['users'];

    var tweet = TweetWithCard.fromCardJson(globalTweets, globalUsers, globalTweets[id]);
    var chains = createTweetChains(globalTweets, globalUsers, instructions);

    return TweetStatus(tweet: tweet, chains: chains, cursorBottom: 'TODO', cursorTop: 'TODO');
  }

  static Future<TweetStatus> searchTweets(String query, {int limit = 25, String? maxId, String? cursor}) async {
    var response = await _twitterApi.client.get(
        Uri.https('api.twitter.com', '/2/search/adaptive.json', {
          ...defaultParams,
          'count': limit.toString(),
          'cursor': cursor,
          'max_id': maxId,
          'q': query,
          'query_source': 'typed_query',
          'pc': '1',
          'spelling_corrections': '1',
        })
    );

    var result = json.decode(response.body);

    return createUnconversationedChains(result, 'sq-I-t', false);
  }

  static Future<List<User>> searchUsers(String query) async => await _twitterApi.userService.usersSearch(
      q: query,
    );

  static Future<List<TrendLocation>> getTrendLocations() async {
    var result = await _cache.getOrCreateAsJSON('trends.locations', Duration(days: 2), () async {
      var locations = await _twitterApi.trendsService.available();

      return jsonEncode(locations.map((e) => e.toJson()).toList());
    });

    return List.from(jsonDecode(result))
        .map((e) => TrendLocation.fromJson(e))
        .toList(growable: false);
  }

  static Future<List<Trends>> getTrends(int location) async {
    var result = await _cache.getOrCreateAsJSON('trends.$location', Duration(minutes: 2), () async {
      var trends = await _twitterApi.trendsService.place(
          id: location
      );

      return jsonEncode(trends.map((e) => e.toJson()).toList());
    });

    return List.from(jsonDecode(result))
      .map((e) => Trends.fromJson(e))
      .toList(growable: false);
  }

  static Future<TweetStatus> getTweets(String id, String type, { int count = 10, String? cursor, bool includeReplies = true, bool includeRetweets = true }) async {
    var query = {
      ...defaultParams,
      'include_tweet_replies': includeReplies ? '1' : '0',
      'include_want_retweets': includeRetweets ? '1' : '0', // This may not actually do anything
      'count': count.toString(),
    };

    if (cursor != null) {
      query['cursor'] = cursor;
    }

    var response = await _twitterApi.client.get(
      Uri.https('api.twitter.com', '/2/timeline/$type/$id.json', query)
    );

    var result = json.decode(response.body);

    return createUnconversationedChains(result, 'tweet', cursor == null);
  }

  static TweetStatus createUnconversationedChains(dynamic result, String tweetIndicator, bool showPinned) {
    var instructions = List.from(result['timeline']['instructions']);

    var addEntries = instructions.firstWhere((e) => e.containsKey('addEntries'))['addEntries']['entries'] as List<dynamic>;

    String? cursorBottom;
    String? cursorTop;

    {
      var cursorBottomEntry = addEntries
        .firstWhere((e) => e['entryId'].contains('cursor-bottom'), orElse: () => null);

      if (cursorBottomEntry != null) {
        cursorBottom = cursorBottomEntry['content']['operation']['cursor']['value'];
      } else {
        // Look for a "replaceEntry" with the cursor
        var cursorBottomReplaceEntry = List.from(result['timeline']['instructions'])
            .where((e) => e.containsKey('replaceEntry'))
            .firstWhere((e) => e['replaceEntry']['entryIdToReplace'].contains('cursor-bottom'), orElse: () => null);

        if (cursorBottomReplaceEntry != null) {
          cursorBottom = cursorBottomReplaceEntry['replaceEntry']['entry']['content']['operation']['cursor']['value'];
        }
      }
    }

    {
      var cursorTopEntry = addEntries
          .firstWhere((e) => e['entryId'].contains('cursor-top'), orElse: () => null);

      if (cursorTopEntry != null) {
        cursorTop = cursorTopEntry['content']['operation']['cursor']['value'];
      } else {
        // Look for a "replaceEntry" with the cursor
        var cursorTopReplaceEntry = List.from(result['timeline']['instructions'])
            .where((e) => e.containsKey('replaceEntry'))
            .firstWhere((e) => e['replaceEntry']['entryIdToReplace'].contains('cursor-top'), orElse: () => null);

        if (cursorTopReplaceEntry != null) {
          cursorTop = cursorTopReplaceEntry['replaceEntry']['entry']['content']['operation']['cursor']['value'];
        }
      }
    }

    var tweets = _createTweets(tweetIndicator, result);

    List<TweetChain> chains = [];
    List<String> threads = [];

    var tweetEntries = addEntries
        .where((e) => e['entryId'].contains(tweetIndicator))
        .sorted((a, b) => b['sortIndex'].compareTo(a['sortIndex']))
        .map((e) => e['content']['item']['content']['tweet']['id'])
        .cast<String>()
        .toList();

    // var conversations = tweets
    //   .values
    //   .map((e) => e.conversationIdStr!)
    //   .toSet();
    //
    // var things = [];

    for (var tweetEntry in tweetEntries) {
      var tweet = tweets[tweetEntry];
      if (tweet == null) {
        log('Unable to find the tweet using the entry ID $tweetEntry');
        continue;
      }

      if (threads.contains(tweet.idStr)) {
        continue;
      }

      var thread = _buildThread(tweets.values, threads, tweet);
      if (thread.length < 2) {
        // Do nothing, for now
        int i = 0;
      } else {
        threads.addAll(thread.map((e) => e.idStr!));
      }

      var chainTweets = thread
          .sorted((a, b) => a.idStr!.compareTo(b.idStr!))
          .toList();

      chains.add(TweetChain(id: chainTweets.first.conversationIdStr!, tweets: chainTweets, isPinned: false));
    }

    if (showPinned) {
      var pinEntry = instructions.firstWhere((e) => e.containsKey('pinEntry'), orElse: () => null);
      if (pinEntry != null) {
        var id = pinEntry['pinEntry']['entry']['content']['item']['content']['tweet']['id'] as String;

        chains.insert(0, TweetChain(id: id, tweets: [tweets[id]!], isPinned: true));
      }
    }

    return TweetStatus(tweet: null, chains: chains, cursorBottom: cursorBottom, cursorTop: cursorTop);
  }

  static List<TweetWithCard> _buildThread(Iterable<TweetWithCard> tweets, List<String> threads, TweetWithCard tweet) {
    List<TweetWithCard> result = [tweet];

    if (threads.contains(tweet.inReplyToStatusIdStr)) {
      return result;
    }

    for (var t in tweets) {
      if (t.idStr == result[0].inReplyToStatusIdStr) {
        result.insert(0, t);
      } else if (t.inReplyToStatusIdStr == result[0].idStr) {
        result.add(t);
      }
    }

    return result;
  }

  static Future<List<User>> getUsers(Iterable<String> ids) async {
    // Split into groups of 100, as the API only supports that many at a time
    List<Future<List<User>>> futures = [];

    var groups = partition(ids, 100);
    for (var group in groups) {
      futures.add(_getUsersPage(group));
    }

    return (await Future.wait(futures))
        .expand((element) => element)
        .toList();
  }

  static Future<List<User>> _getUsersPage(Iterable<String> ids) async {
    var response = await _twitterApi.client.get(Uri.https('api.twitter.com', '/1.1/users/lookup.json', {
      'user_id': ids.join(','),
    }));

    var result = json.decode(response.body);

    return List.from(result)
        .map((e) => User.fromJson(e))
        .toList(growable: false);
  }

  static Map<String, TweetWithCard> _createTweets(String entryPrefix, Map<String, dynamic> result) {
    var globalTweets = result['globalObjects']['tweets'] as Map<String, dynamic>;
    var instructions = result['timeline']['instructions'];
    var globalUsers = result['globalObjects']['users'];

    var tweets = globalTweets.values
        .map((e) => TweetWithCard.fromCardJson(globalTweets, globalUsers, e))
        // .sorted((a, b) => b.createdAt!.compareTo(a.createdAt!))
        .toList();
    
    return Map.fromIterable(tweets, key: (e) => e.idStr, value: (e) => e);

    // var entries = instructions[0]['addEntries']['entries'] as List<dynamic>;

    // entries.sort((a, b) => b['sortIndex'].compareTo(a['sortIndex']));

    // return entries
    //     .where((entry) => entry['entryId'].startsWith(entryPrefix) as bool)
    //     .where((entry) => globalTweets.containsKey(entry['content']['item']['content']['tweet']['id']))
    //     .map<TweetWithCard>((entry) => TweetWithCard.fromCardJson(globalTweets, globalUsers, globalTweets[entry['content']['item']['content']['tweet']['id']]));
  }
}

class TweetWithCard extends Tweet {
  Map<String, dynamic>? card;
  String? conversationIdStr;
  TweetWithCard? inReplyToWithCard;
  TweetWithCard? quotedStatusWithCard;
  TweetWithCard? retweetedStatusWithCard;
  bool? isTombstone;

  TweetWithCard();

  Map<String, dynamic> toJson() {
    var json = super.toJson();
    json['card'] = card;
    json['conversationIdStr'] = conversationIdStr;
    json['inReplyToWithCard'] = inReplyToWithCard?.toJson();
    json['quotedStatusWithCard'] = quotedStatusWithCard?.toJson();
    json['retweetedStatusWithCard'] = retweetedStatusWithCard?.toJson();
    json['isTombstone'] = isTombstone;

    return json;
  }

  factory TweetWithCard.tombstone(dynamic e) {
    var tweetWithCard = TweetWithCard();
    tweetWithCard.idStr = '';
    tweetWithCard.isTombstone = true;
    tweetWithCard.text = ((e['richText']?['text'] ?? '') as String).replaceFirst(' Learn more', '');

    return tweetWithCard;
  }

  factory TweetWithCard.fromJson(Map<String, dynamic> e) {
    var tweet = Tweet.fromJson(e);

    var tweetWithCard = TweetWithCard();
    tweetWithCard.card = e['card'];
    tweetWithCard.conversationIdStr = e['conversationIdStr'];
    tweetWithCard.createdAt = tweet.createdAt;
    tweetWithCard.entities = tweet.entities;
    tweetWithCard.displayTextRange = tweet.displayTextRange;
    tweetWithCard.extendedEntities = tweet.extendedEntities;
    tweetWithCard.favorited = tweet.favorited;
    tweetWithCard.favoriteCount = tweet.favoriteCount;
    tweetWithCard.fullText = tweet.fullText;
    tweetWithCard.idStr = tweet.idStr;
    tweetWithCard.inReplyToScreenName = tweet.inReplyToScreenName;
    tweetWithCard.inReplyToStatusIdStr = tweet.inReplyToStatusIdStr;
    tweetWithCard.inReplyToUserIdStr = tweet.inReplyToUserIdStr;
    tweetWithCard.inReplyToWithCard = e['inReplyToWithCard'] == null ? null : TweetWithCard.fromJson(e['inReplyToWithCard']);
    tweetWithCard.isQuoteStatus = tweet.isQuoteStatus;
    tweetWithCard.isTombstone = e['is_tombstone'];
    tweetWithCard.lang = tweet.lang;
    tweetWithCard.quoteCount = tweet.quoteCount;
    tweetWithCard.quotedStatusIdStr = tweet.quotedStatusIdStr;
    tweetWithCard.quotedStatusPermalink = tweet.quotedStatusPermalink;
    tweetWithCard.quotedStatusWithCard = e['quotedStatusWithCard'] == null ? null : TweetWithCard.fromJson(e['quotedStatusWithCard']);
    tweetWithCard.replyCount = tweet.replyCount;
    tweetWithCard.retweetCount = tweet.retweetCount;
    tweetWithCard.retweeted = tweet.retweeted;
    tweetWithCard.retweetedStatus = tweet.retweetedStatus;
    tweetWithCard.retweetedStatusWithCard = e['retweetedStatusWithCard'] == null ? null : TweetWithCard.fromJson(e['retweetedStatusWithCard']);
    tweetWithCard.source = tweet.source;
    tweetWithCard.text = tweet.text;
    tweetWithCard.user = tweet.user;

    tweetWithCard.coordinates = tweet.coordinates;
    tweetWithCard.truncated = tweet.truncated;
    tweetWithCard.place = tweet.place;
    tweetWithCard.possiblySensitive = tweet.possiblySensitive;
    tweetWithCard.possiblySensitiveAppealable = tweet.possiblySensitiveAppealable;

    return tweetWithCard;
  }

  factory TweetWithCard.fromCardJson(Map<String, dynamic> tweets, Map<String, dynamic> users, Map<String, dynamic> e) {
    TweetWithCard tweet = TweetWithCard();
    tweet.card = e['card'];
    tweet.conversationIdStr = e['conversation_id_str'];
    tweet.createdAt = convertTwitterDateTime(e['created_at']);
    tweet.entities = e['entities'] == null ? null : Entities.fromJson(e['entities']);
    tweet.extendedEntities = e['extended_entities'] == null ? null : Entities.fromJson(e['extended_entities']);
    tweet.favorited = e['favorited'] as bool?;
    tweet.favoriteCount = e['favorite_count'] as int?;
    tweet.fullText = e['full_text'] as String?;
    tweet.idStr = e['id_str'] as String?;
    tweet.inReplyToScreenName = e['in_reply_to_screen_name'] as String?;
    tweet.inReplyToStatusIdStr = e['in_reply_to_status_id_str'] as String?;
    tweet.inReplyToUserIdStr = e['in_reply_to_user_id_str'] as String?;
    tweet.isQuoteStatus = e['is_quote_status'] as bool?;
    tweet.isTombstone = e['is_tombstone'] as bool?;
    tweet.lang = e['lang'] as String?;
    tweet.quoteCount = e['quote_count'] as int?;
    tweet.quotedStatusIdStr = e['quoted_status_id_str'] as String?;
    tweet.quotedStatusPermalink = e['quoted_status_permalink'] == null ? null : QuotedStatusPermalink.fromJson(e['quoted_status_permalink']);
    tweet.replyCount = e['reply_count'] as int?;
    tweet.retweetCount = e['retweet_count'] as int?;
    tweet.retweeted = e['retweeted'] as bool?;
    tweet.source = e['source'] as String?;
    tweet.text = e['text'] ?? e['full_text'] as String?;
    tweet.user = e['user_id_str'] == null ? null : User.fromJson(users[e['user_id_str']]);

    var retweetedStatus = e['retweeted_status_id_str'] == null ? null : TweetWithCard.fromCardJson(tweets, users, tweets[e['retweeted_status_id_str']]);
    tweet.retweetedStatus = retweetedStatus;
    tweet.retweetedStatusWithCard = retweetedStatus;

    // Some quotes aren't returned, even though we're given their ID, so double check and don't fail with a null value
    var quoteId = e['quoted_status_id_str'];
    if (quoteId != null && tweets[quoteId] != null) {
      var quotedStatus = TweetWithCard.fromCardJson(tweets, users, tweets[quoteId]);

      tweet.quotedStatus = quotedStatus;
      tweet.quotedStatusWithCard = quotedStatus;
    }

    var inReplyToId = e['in_reply_to_status_id_str'];
    if (inReplyToId != null && tweets[inReplyToId] != null) {
      var inReplyTo = TweetWithCard.fromCardJson(tweets, users, tweets[inReplyToId]);

      tweet.inReplyToWithCard = inReplyTo;
    }

    tweet.displayTextRange = (e['display_text_range'] as List<dynamic>?)
        ?.map((e) => e as int)
        .toList();

    // TODO
    tweet.coordinates = null;
    tweet.truncated = null;
    tweet.place = null;
    tweet.possiblySensitive = null;
    tweet.possiblySensitiveAppealable = null;

    return tweet;
  }
}

class TweetChain {
  final String id;
  final List<TweetWithCard> tweets;
  final bool isPinned;

  TweetChain({required this.id, required this.tweets, required this.isPinned});
}

class TweetStatus {
  // final TweetChain after;
  // final TweetChain before;
  final TweetWithCard? tweet;
  final String? cursorBottom;
  final String? cursorTop;
  final List<TweetChain> chains;

  TweetStatus({required this.tweet, required this.chains, required this.cursorBottom, required this.cursorTop});
}