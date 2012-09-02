{-
    LogFormat.hs
    Copyright (C) 2012 Harold Lee

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{- | LogFormat is a Haskell module that makes it trivial to parse access
     log records.
 -}
module Text.LogFormat where

import Data.Map
import Text.Parsec

-- | Parser a is a Parsec parser for Strings that parses an 'a'.
type Parser a = Parsec String () a

-- | A LogFormat string is made up of literal strings (which must match
--   exactly) and % directives that match a certain pattern and can have
--   an optional modifier string.
data Rule = Literal String
          | Keyword Char (Maybe String)
    deriving Show

logFormatParser :: String -> Either ParseError (Parser (Map String String))
logFormatParser logFormat = parse rulesParser parserName logFormat
  where rulesParser = do rules <- logFormatSpecParser
                         return $ buildLogRecordParser rules
        parserName = "Parsing LogFormat [" ++ logFormat ++ "]"

{-
  Tokenize the LogFormat string that specifies the grammar
  for log records into a list of Rules.
 -}
logFormatSpecParser = do rules <- many1 (rule <|> literal)
                         return $ combineLiterals rules

combineLiterals [] = []
combineLiterals (Literal l1 : Literal l2 : rs) =
  combineLiterals $ Literal (l1 ++ l2) : rs
combineLiterals (r:rs) = r : combineLiterals rs

-- Parser for a single % rule in the LogFormat string, including %%.
rule = try simpleRule <|> try literalRule <|> try sRule <|> iRule

simpleRule = do char '%'
                format <- oneOf "aABbCDefhHlmnopPqrtTuUvVXIO"
                return $ Keyword format Nothing

literalRule = do string "%%"
                 return $ Literal "%"

sRule = do char '%'
           mod <- optionMaybe $ string ">"
           char 's'
           return $ Keyword 's' mod

iRule = do char '%'
           mod <- optionMaybe $ between (char '{') (char '}') (many $ alphaNum <|> char '-')
           char 'i'
           return $ Keyword 'i' mod

literal = do str <- many1 $ noneOf "%"
             return $ Literal str

buildLogRecordParser :: [Rule] -> Parser (Map String String)
buildLogRecordParser rules = Prelude.foldr combiner eolParser rules
  where eolParser = do newline
                       return empty
        combiner (Keyword 'i' mod) followingParser = headerParser mod followingParser
        combiner rule followingParser = do m1 <- parserFor rule
                                           m2 <- followingParser
                                           return $ union (maybePairToMap m1) m2

headerParser mod followingParser = do
    value <- manyTill anyChar (lookAhead (try followingParser))
    rest <- followingParser
    return $ union rest (singleton key value)
  where key = case mod of
                Nothing -> "header"
                Just m -> "header:" ++ m

maybePairToMap (Just (k,v)) = singleton k v
maybePairToMap Nothing = empty

mapAppender map [] = map
mapAppender map (v1:vs) = mapAppender (insert v1 v1 map) vs

-- | Update a map with each of the key-value pairs built by some instances of a
--   Monad. We'll use it to take a bunch of 'Parser's that each parse an
--   optional key-value pair and merge those into a 'Parser' that builds a 'Map'.
combineMapBuilders :: (Monad m, Ord k) =>
                        [m (Maybe (k,v))] -> Map k v -> m (Map k v)
combineMapBuilders [] map = return map
combineMapBuilders (p1:ps) map = do
  result <- p1
  case result of
    Nothing -> combineMapBuilders ps map
    Just (k,v) -> combineMapBuilders ps (insert k v map)

-- | Take a parser and convert it to parse a Maybe (key, value) pair instead
--   of just a value.
keyValueParser :: a -> Parser b -> Parser (Maybe (a, b))
keyValueParser key parser = do value <- parser
                               return $ Just (key, value)

concatParser :: String -> Parser (String -> String -> String)
concatParser sepStr = do value <- string sepStr
                         return (\a b -> a ++ sepStr ++ b)

-- | Parser for IP addresses
ipParser :: Parser String
ipParser = chainl1 (many1 digit) (concatParser ".")

-- | Parser for hostnames
hostnameParser :: Parser String
hostnameParser = chainl1 (many1 alphaNum) (concatParser ".")

digits = many1 digit

-- | Build a parser for a 'Rule'.
--
--   For 'Keyword' 'Rule's:
--
--   Take a character that is used to define a field in the LogFormat
--   specification and return a 'Parser' that will parse out a key-value
--   for that field from the input. For example, %U in a LogFormat means
--   the URL path, so a URL path parser is available as
--
--   @
--       parserFor (Keyword \'U\' Nothing)
--   @
parserFor :: Rule -> Parser (Maybe (String, String))

-- Build a parser that matches an exact string literal and returns Nothing.
parserFor (Literal lit) = do string lit
                             return Nothing

-- The URL path requested, not including any query string.
parserFor (Keyword 'U' Nothing) = keyValueParser "path" (many1 $ alphaNum <|> char '/')

-- The request method
parserFor (Keyword 'm' Nothing) = keyValueParser "method" $ (many1 $ oneOf ['A'..'Z'])

-- The process ID or thread id of the child that serviced the request.
parserFor (Keyword 'P' Nothing) = keyValueParser "processId" digits

-- The time taken to serve the request, in seconds.
parserFor (Keyword 'T' Nothing) = keyValueParser "timeTakenSeconds" digits

-- The time taken to serve the request, in microseconds.
parserFor (Keyword 'D' Nothing) = keyValueParser "timeTakenMicroseconds" digits

-- Size of response in bytes, excluding HTTP headers.
parserFor (Keyword 'B' Nothing) = keyValueParser "bytes" $ digits

-- Size of response in bytes, excluding HTTP headers.
-- In CLF format, i.e. a '-' rather than a 0 when no bytes are sent.
parserFor (Keyword 'b' Nothing) = keyValueParser "bytesCLF" valueParser
  where valueParser = digits <|> (string "-")

-- Remote IP-address
parserFor (Keyword 'a' Nothing) = keyValueParser "remoteIP" ipParser

-- Local IP-address
parserFor (Keyword 'A' Nothing) = keyValueParser "localIP" ipParser

-- The query string (prepended with a ? if a query string exists, otherwise an empty string)
parserFor (Keyword 'q' Nothing) = do value <- (string "") <|> queryStringParser
                                     return $ Just ("queryString", value)
  where queryStringParser = do char '?'
                               qs <- many1 $ alphaNum <|> char '&' <|> char '='
                               return $ "?" ++ qs

-- Status.
-- For requests that got internally redirected, this is the status of the *original* request,
-- %...>s for the last.
parserFor (Keyword 's' mod) = keyValueParser (format mod) (many1 alphaNum)
  where format Nothing = "statusOriginal"
        format (Just ">") = "statusLast"

-- Remote host
parserFor (Keyword 'h' Nothing) = keyValueParser "remoteHost" hostnameParser

-- The canonical ServerName of the server serving the request.
parserFor (Keyword 'v' Nothing) = keyValueParser "canonicalServerName" hostnameParser

-- The server name according to the UseCanonicalName setting.
parserFor (Keyword 'V' Nothing) = keyValueParser "serverName" hostnameParser

-- Next up: l t r
