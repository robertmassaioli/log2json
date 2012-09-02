{-
    LogFormatTests.hs
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
module LogFormatTests where

import Text.LogFormat

import Data.Map as M
import Test.HUnit
import Text.Parsec as P

main = runTestTT allTests

allTests = TestList [testU, testLiteral, testBadLit, testUAndLit,
                     testGetMethod, testPostMethod, testRemoteIP, testLocalIP,
                     testBytesCLF, testBytesCLF2, testBytesCLFBad1, testBytesCLFBad2,
                     testThreeGroups,
                     testHeader, testHeaderQuotes, testHeaderAndCo, testAnonymousHeader]

data ParseResult a = Failure String
                   | SuccessForLiteral
                   | Success a
  deriving (Show, Eq, Ord)

-- Helper to build a bunch of parser test cases.
parserTest name message expected parser input =
    name ~: do assertEqual message expected actual
  where actual = let result = P.parse parser ("Unit Test: " ++ name) input in
                   case result of
                     Left parseError    -> Failure (show parseError)
                     Right Nothing      -> SuccessForLiteral
                     Right (Just value) -> Success value

eofParser p = do value <- p
                 eof
                 return value

literalParser lit = parserFor (Literal lit)

charRuleParser ch = parserFor (Keyword ch Nothing)

testU = parserTest "testU" "Should parse path" expected parser "/abc"
  where expected = Success ("path", "/abc")
        parser = eofParser $ charRuleParser 'U'

testLiteral = parserTest "testLiteral" "Should match literal" expected parser "hi"
  where expected = SuccessForLiteral :: ParseResult (String, String)
        parser = literalParser "hi"

testBadLit = parserTest "testBadLit" "Should fail to match literal" expected parser "def"
  where expected = Failure errMessage  :: ParseResult (String, String)
        errMessage = "\"Unit Test: testBadLit\" (line 1, column 1):\nunexpected \"d\"\nexpecting \"abc\""
        parser = literalParser "abc"

testUAndLit = parserTest "testUAndLit" "Should match a path and literal" expected parser "/path/to/somewhere?a=1"
  where expected = Success (M.fromList [("path", "/path/to/somewhere")])
        rawParser = combineMapBuilders [charRuleParser 'U', literalParser "?a=1"] M.empty
        parser = do result <- rawParser
                    return $ Just result

testGetMethod = parserTest "testGetMethod" "Should accept GET method" expected parser "methodGET"
  where expected = Success (M.fromList [("method", "GET")])
        rawParser = combineMapBuilders [literalParser "method", charRuleParser 'm'] M.empty
        parser = do result <- rawParser
                    return $ Just result


testPostMethod = parserTest "testPostMethod" "Should accept POST method" expected parser "methodPOST"
  where expected = Success (M.fromList [("method", "POST")])
        rawParser = combineMapBuilders [literalParser "method", charRuleParser 'm'] M.empty
        parser = do result <- rawParser
                    return $ Just result

testRemoteIP = parserTest "testRemoteIP" "Should handle remote IP address" expected parser "123.45.67.89"
  where expected = Success ("remoteIP", "123.45.67.89")
        parser = eofParser $ charRuleParser 'a'

testLocalIP = parserTest "testLocalIP" "Should handle local IP address" expected parser "123.45.67.89"
  where expected = Success ("localIP", "123.45.67.89")
        parser = eofParser $ charRuleParser 'A'

testBytesCLF = parserTest "testBytesCLF" "Should handle bytes CLF value -" expected parser "-"
  where expected = Success ("bytesCLF", "-")
        parser = charRuleParser 'b'

testBytesCLF2 = parserTest "testBytesCLF2" "Should handle bytes CLF numbers" expected parser "1234"
  where expected = Success ("bytesCLF", "1234")
        parser = charRuleParser 'b'

testBytesCLFBad1 = parserTest "testBytesCLFBad1" "Should fail with comma" expected parser "1,234"
  where expected = Failure errMessage  :: ParseResult (String, String)
        errMessage = "\"Unit Test: testBytesCLFBad1\" (line 1, column 2):\nunexpected ','\nexpecting digit or end of input"
        parser = eofParser $ charRuleParser 'b'

testBytesCLFBad2 = parserTest "testBytesCLFBad2" "Should fail for letters" expected parser "abc"
  where expected = Failure errMessage  :: ParseResult (String, String)
        errMessage = "\"Unit Test: testBytesCLFBad2\" (line 1, column 1):\nunexpected \"a\"\nexpecting digit or \"-\""
        parser = charRuleParser 'b'

parseRecordTest testName logFormat inputLine expected =
    testName ~: do parser <- buildParser logFormat
                   map <- applyParser (eofParser parser) inputLine
                   assertEqual "Checking log record parse result" expected map
  where buildParser logFormat = case logFormatParser logFormat of
          Left parseErr -> do assertFailure $ "Failed to compile LogFormat: " ++ show parseErr ; fail ""
          Right parser  -> return parser
        applyParser parser inputLine = case parse parser testName inputLine of
          Left parseErr -> do assertFailure $ "Failed to parse sample log line: " ++ show parseErr ; fail ""
          Right map -> return map

testThreeGroups = parseRecordTest "testThreeGroups" "%%%b%%%s%%%>s" "%123%abc%def\n" exp
  where exp = M.fromList [("statusOriginal", "abc"), ("statusLast", "def"), ("bytesCLF", "123")]

testHeader = parseRecordTest "testHeader"  "%{Content-Type}i" "hello world\n" exp
  where exp = M.fromList [("header:Content-Type", "hello world")]

testHeaderQuotes = parseRecordTest "testHeaderQuotes" "'%{foo}i'" "'''\n" exp
  where exp = M.fromList [("header:foo", "'")]

testHeaderAndCo = parseRecordTest "testHeaderAndCo"  "%%%b'%{Content-Type}i'%B%%" "%123'hello world'456%\n" exp
  where exp = M.fromList [("bytesCLF", "123"), ("header:Content-Type", "hello world"), ("bytes", "456")]

testAnonymousHeader = parseRecordTest "testAnonymousHeader" "%i" "hello\n" exp
  where exp = M.fromList [("header", "hello")]

-- TODO : test these log formats

-- Common Log Format with Virtual Host
commonLogFormat = "%v %h %l %u %t \"%r\" %>s %b"

-- NCSA extended/combined log format
ncsaLogFormat = "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-agent}i\""

defaultLogFormat = "%h %l %u %t \"%r\" %>s %b"
