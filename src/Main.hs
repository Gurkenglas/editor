{-# LANGUAGE TemplateHaskell #-}

import Graphics.Vty
import Data.List (foldr, intercalate)
import Control.Lens
import Control.Lens.TH
import Control.Exception (finally)
import System.Environment (getArgs)
import Text.Highlighting.Kate (highlightAs, TokenType(..))

data Zipper =
  Zipper {
    _linesAbove :: [String],
    _linesBelow :: [String],
    _charsLeft  :: [Char],
    _charsRight :: [Char]
  }
makeLenses ''Zipper

zipperLines :: Zipper -> [String]
zipperLines z =
  reverse (map reverse (view linesAbove z)) ++
  [reverse (view charsLeft z) ++ view charsRight z] ++
  view linesBelow z

position :: Zipper -> Cursor
position z = 
  Cursor
    (length $ view charsLeft z)
    (length $ view linesAbove z)

insert :: Char -> Zipper -> Zipper
insert c =
  over charsLeft $ (:) c

backspace :: Zipper -> Zipper
backspace z =
  case view charsLeft z of
    "" ->
      case view linesAbove z of
        [] -> z
        (line : lines) -> set charsLeft line (set linesAbove lines z)
    (_:xs) -> set charsLeft xs z

delete :: Zipper -> Zipper
delete z =
  case view charsRight z of
    "" ->
      case view linesBelow z of
        [] -> z
        (line : lines) -> set charsRight line (set linesBelow lines z)
    (_:xs) -> set charsRight xs z

newline :: Zipper -> Zipper
newline z =
  let
    new = view charsLeft z
    z' = over linesAbove ((:) new) z
  in
    set charsLeft "" z'

goUp :: Zipper -> Zipper
goUp z =
  case view linesAbove z of
    [] -> z
    (c:cs) ->
      let
        leftChars = view charsLeft z
        rightChars = view charsRight z
        belowLines = view linesBelow z
        n = length leftChars
        c' = reverse c
        leftChars' = reverse $ take n c'
        rightChars' = drop n c'
        line = reverse leftChars ++ rightChars
      in
        Zipper cs (line : belowLines) leftChars' rightChars'

goDown :: Zipper -> Zipper
goDown z =
  case view linesBelow z of
    [] -> z
    (c:cs) ->
      let
        leftChars = view charsLeft z
        rightChars = view charsRight z
        aboveLines = view linesAbove z
        n = length leftChars
        leftChars' = reverse $ take n c
        rightChars' = drop n c
        line = reverse rightChars ++ leftChars
      in
        Zipper (line : aboveLines) cs leftChars' rightChars'

goLeft :: Zipper -> Zipper
goLeft z =
  case view charsLeft z of
    "" ->
      case view linesAbove z of
        [] -> z
        (line : lines) ->
          let
            rightChars = view charsRight z
            belowLines = view linesBelow z
          in
            Zipper lines (rightChars : belowLines) line []
    (c:cs) ->
       set charsLeft cs $ over charsRight ((:) c) z

goRight :: Zipper -> Zipper
goRight z =
  case view charsRight z of
    "" ->
      case view linesBelow z of
        [] -> z
        (line : lines) ->
          let
            leftChars = view charsLeft z
            aboveLines = view linesAbove z
          in
            Zipper (leftChars : aboveLines) lines [] line
    (c:cs) ->
       set charsRight cs $ over charsLeft ((:) c) z

shiftCursorRight :: Int -> Cursor -> Cursor
shiftCursorRight _ NoCursor = NoCursor
shiftCursorRight n (Cursor l t) = Cursor (l + n) t

data State =
  State {
    _zipper :: Zipper
  }
makeLenses ''State

loop vty bounds state = do
  render vty state

  e <- nextEvent vty
  handleEvent e
 where
  showN m n =
    let
      s = show n
    in
      (take (m - length s) $ repeat ' ') ++ s

  typeToStyle KeywordTok = defAttr `withForeColor` yellow `withStyle` bold
  typeToStyle DataTypeTok = defAttr `withForeColor` cyan `withStyle` bold
  typeToStyle CommentTok = defAttr `withForeColor` red
  typeToStyle OperatorTok = defAttr `withForeColor` yellow `withStyle` bold
  typeToStyle StringTok = defAttr `withForeColor` magenta
  typeToStyle _ = defAttr

  renderToken (t, s) =
    string (typeToStyle t) s

  renderLine line =
    string defAttr " " <|> (horizCat $ map renderToken line)

  picture =
    let
      z = view zipper state 
      lines = zipperLines z
      numLines = length lines

      lineNumWidth = length (show numLines)
      lineNumStyle = defAttr `withStyle` bold `withForeColor` yellow
      lineNumbers = foldr1 (<->) $ map (string lineNumStyle . showN lineNumWidth) [1..numLines]

      highlighted = highlightAs "haskell" $ intercalate "\n" lines

      text = vertCat $ map renderLine highlighted
      image = lineNumbers <|> text
      cursor = shiftCursorRight (1 + lineNumWidth) $ position z
    in
      (picForImage image) { picCursor = cursor }

  render vty state =
    update vty picture

  handleEvent (EvKey (KChar 'q') [MCtrl]) =
    return ()
  handleEvent (EvKey (KChar x) []) =
    loop vty bounds $ over zipper (insert x) $ state
  handleEvent (EvKey KUp []) =
    loop vty bounds $ over zipper goUp state
  handleEvent (EvKey KDown []) =
    loop vty bounds $ over zipper goDown state
  handleEvent (EvKey KLeft []) =
    loop vty bounds $ over zipper goLeft state
  handleEvent (EvKey KRight []) =
    loop vty bounds $ over zipper goRight state
  handleEvent (EvKey KBS []) =
    loop vty bounds $ over zipper backspace state
  handleEvent (EvKey KDel []) =
    loop vty bounds $ over zipper delete state
  handleEvent (EvKey KEnter []) =
    loop vty bounds $ over zipper newline state
  handleEvent (EvResize width height) =
    loop vty (width, height) state
  handleEvent e = do
    print ("unknown event " ++ show e)
    loop vty bounds state

loadState [] =
  return $ State $ Zipper [] [] [] []
loadState [filename] = do
  l <- lines <$> readFile filename
  return $
    case l of
      [] -> State $ Zipper [] [] [] []
      (x:xs) -> State $ Zipper [] xs [] x

main = do
  args <- getArgs
  state <- loadState args
  cfg <- standardIOConfig
  vty <- mkVty cfg
  bounds <- displayBounds $ outputIface vty

  finally
    (loop vty bounds state)
    (shutdown vty)
