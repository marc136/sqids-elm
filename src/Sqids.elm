module Sqids exposing
    ( EncodeError(..)
    , decode
    , decodeWith
    , encodeList
    , encodeListWith
    , errToString
    , maxSafeInt
    , toId
    )

import Array exposing (Array)
import Array.Extra
import Defaults exposing (Context)
import List.Extra
import Result.Extra
import Set exposing (Set)
import Shuffle
import Sqids.Context


type EncodeError
    = NegativeNumber Int
    | TooHighInteger Int
    | MaxRegenerateAttempts


{-| These texts are taken from
<https://github.com/sqids/sqids-spec/blob/40f407169fa0f555b93a197ff0a9e974efa9fba6/src/index.ts>
-}
errToString : EncodeError -> String
errToString error =
    case error of
        NegativeNumber _ ->
            "Encoding supports numbers between 0 and " ++ String.fromInt maxSafeInt

        TooHighInteger _ ->
            "Encoding supports numbers between 0 and " ++ String.fromInt maxSafeInt

        MaxRegenerateAttempts ->
            "Reached max attempts to re-generate the ID"


decode : String -> List Int
decode =
    decodeWith Defaults.context


{-| Decodes an ID back into an array of unsigned integers
These are the cases where the return value might be an empty array:

  - Empty ID / empty string
  - Non-alphabet character is found within ID

-}
decodeWith : Context -> String -> List Int
decodeWith context id =
    case String.uncons id of
        Nothing ->
            -- string is empty, return an empty list
            []

        -- first character is always the `prefix`
        Just ( prefix_, idWithoutPrefix ) ->
            let
                initialAlphabet =
                    Sqids.Context.getAlphabet context
                        |> Array.toList

                alphabetSet : Set Char
                alphabetSet =
                    Set.fromList initialAlphabet

                isInAlphabet : Char -> Bool
                isInAlphabet char =
                    Set.member char alphabetSet

                findProperAlphabet : List Char -> DecodeWithLoop -> Result DecodeError (List Char)
                findProperAlphabet chars acc =
                    case ( acc, chars ) of
                        ( SearchForPrefix { prefix }, [] ) ->
                            Err <| CharacterNotInAlphabet prefix

                        ( SearchForPrefix { prefix, beforePrefix }, first :: rest ) ->
                            if isInAlphabet first then
                                if first == prefix then
                                    ValidateAfterPrefix { chunk1 = beforePrefix, chunk2 = [ prefix ] }
                                        |> findProperAlphabet rest

                                else
                                    SearchForPrefix { prefix = prefix, beforePrefix = first :: beforePrefix }
                                        |> findProperAlphabet rest

                            else
                                CharacterNotInAlphabet first |> Err

                        ( ValidateAfterPrefix { chunk1, chunk2 }, [] ) ->
                            Ok (chunk1 ++ chunk2)

                        ( ValidateAfterPrefix { chunk1, chunk2 }, first :: rest ) ->
                            if isInAlphabet first then
                                ValidateAfterPrefix { chunk1 = chunk1, chunk2 = first :: chunk2 }
                                    |> findProperAlphabet rest

                            else
                                Err <| CharacterNotInAlphabet first
            in
            case
                SearchForPrefix { prefix = prefix_, beforePrefix = [] }
                    |> findProperAlphabet initialAlphabet
            of
                Ok alphabet ->
                    decodeWithAlphabet (Array.fromList alphabet) idWithoutPrefix

                Err _ ->
                    []


type DecodeWithLoop
    = SearchForPrefix { prefix : Char, beforePrefix : List Char }
    | ValidateAfterPrefix { chunk1 : List Char, chunk2 : List Char }


type DecodeError
    = EmptyString
    | CharacterNotInAlphabet Char


decodeWithAlphabet : Array Char -> String -> List Int
decodeWithAlphabet alphabet id =
    decodeWithAlphabetHelper [] id alphabet


decodeWithAlphabetHelper : List Int -> String -> Array Char -> List Int
decodeWithAlphabetHelper reversedIdNumbers idString alphabet =
    let
        separator =
            arrayGetInBounds 0 alphabet |> String.fromChar |> Debug.log "separator"
    in
    --  we need the first part to the left of the separator to decode the number
    case String.split separator idString |> Debug.log "chunks" of
        [] ->
            List.reverse reversedIdNumbers

        "" :: _ ->
            -- if chunk is empty, we are done (the rest are junk characters)
            List.reverse reversedIdNumbers

        chunk :: _ ->
            -- decode the number without using the `separator` character
            let
                alphabetWithoutSeparator =
                    Array.slice 1 (Array.length alphabet) alphabet

                number =
                    toNumber (String.toList chunk) alphabetWithoutSeparator
            in
            decodeWithAlphabetHelper (number :: reversedIdNumbers)
                (String.dropLeft (String.length chunk + 1) idString)
                (shuffle alphabet)


toNumber : List Char -> Array Char -> Int
toNumber id alphabet =
    List.foldl (\v a -> a * Array.length alphabet + findIndexInArray v alphabet) 0 id


findIndexInArray : a -> Array a -> Int
findIndexInArray a array =
    let
        inner index =
            Array.get index array
                |> Maybe.andThen
                    (\value ->
                        if value == a then
                            Just index

                        else
                            inner (index + 1)
                    )
    in
    inner 0
        |> Maybe.withDefault -1


encodeList : List Int -> Result EncodeError String
encodeList =
    encodeListWith Defaults.context


encodeListWith : Context -> List Int -> Result EncodeError String
encodeListWith context values =
    if values == [] then
        Ok ""

    else
        case validInput values of
            Ok () ->
                encodeNumbers context 0 values

            Err err ->
                Err err


validInput : List Int -> Result EncodeError ()
validInput list =
    case list of
        [] ->
            Ok ()

        first :: rest ->
            if first < 0 then
                Err <| NegativeNumber first

            else if first > maxSafeInt then
                Err <| TooHighInteger first

            else
                validInput rest


maxSafeInt : Int
maxSafeInt =
    -- 2^53 - 1 (`Number.MAX_SAFE_INTEGER` in JS)
    9007199254740991


encodeNumbers : Context -> Int -> List Int -> Result EncodeError String
encodeNumbers context increment numbers =
    let
        initialAlphabet : Array Char
        initialAlphabet =
            Sqids.Context.getAlphabet context

        alphabetLength =
            Array.length initialAlphabet
    in
    -- if increment is greater than alphabet length, we've reached max attempts
    if increment > alphabetLength then
        Err MaxRegenerateAttempts

    else
        let
            -- get a semi-random offset from input numbers
            offset =
                generateOffsetFromInputs initialAlphabet numbers
                    + increment
                    |> modBy alphabetLength
                    |> Debug.log "offset"

            --  re-arrange alphabet so that second-half goes in front of the first-half
            reorderedAlphabet =
                Array.append (Array.slice offset alphabetLength initialAlphabet)
                    (Array.slice 0 offset initialAlphabet)
                    |> Debug.log "reordered alphabet"

            -- `prefix` is the first character in the generated ID, used for randomization
            prefix =
                arrayGetInBounds 0 reorderedAlphabet

            -- reverse alphabet (otherwise for [0, x] `offset` and `separator` will be the same char)
            reversedAlphabet =
                Array.Extra.reverse reorderedAlphabet
                    |> Debug.log "reversed alphabet"

            {- TODO list
                // final ID will always have the `prefix` character at the beginning
               const ret = [prefix];

               // encode input array
               for (let i = 0; i != numbers.length; i++) {
                   const num = numbers[i];

                   // the first character of the alphabet is going to be reserved for the `separator`
                   const alphabetWithoutSeparator = alphabet.slice(1);
                   ret.push(this.toId(num, alphabetWithoutSeparator));

                   // if not the last number
                   if (i < numbers.length - 1) {
                       // `separator` character is used to isolate numbers within the ID
                       ret.push(alphabet.slice(0, 1));

                       // shuffle on every iteration
                       alphabet = this.shuffle(alphabet);
                   }
               }

               // join all the parts to form an ID
               let id = ret.join('');
            -}
            id =
                let
                    func : Int -> Int -> { alphabet : Array Char, id : List String } -> { alphabet : Array Char, id : List String }
                    func index num last =
                        let
                            _ =
                                Debug.log ("step " ++ String.fromInt index) { num = num, last = last }

                            alphabetWithoutSeparator =
                                Array.slice 1 alphabetLength last.alphabet

                            separator =
                                arrayGetInBounds 0 last.alphabet

                            id_ : String
                            id_ =
                                toId num alphabetWithoutSeparator
                        in
                        if index < (List.length numbers - 1) then
                            { id = String.fromChar separator :: id_ :: last.id
                            , alphabet = shuffle last.alphabet
                            }

                        else
                            { id = id_ :: last.id
                            , alphabet = last.alphabet
                            }
                in
                List.Extra.indexedFoldl func { alphabet = reversedAlphabet, id = [ String.fromChar prefix ] } numbers
                    |> padId (Sqids.Context.getMinLength context)
        in
        -- TODO handle blocked words
        -- https://github.com/sqids/sqids-spec/blob/40f407169fa0f555b93a197ff0a9e974efa9fba6/src/index.ts#L165-L168
        {-
           // if ID has a blocked word anywhere, restart with a +1 increment
           if (this.isBlockedId(id)) {
               id = this.encodeNumbers(numbers, increment + 1);
           }
        -}
        if Sqids.Context.containsBlockedWord context id then
            encodeNumbers context (increment + 1) numbers

        else
            Ok id


{-| TESTED

    let alphabet = "abc"
    let numbers = [0,1,2]
    let offset =
        numbers.reduce((a, v, i) => {
            const cp = alphabet[v % alphabet.length].codePointAt(0)
            console.log({a, v, i, cp})
            return cp + i + a;
        }, numbers.length) % alphabet.length;

-}
generateOffsetFromInputs : Array Char -> List Int -> Int
generateOffsetFromInputs alphabet numbers =
    let
        alphabetLength =
            Array.length alphabet
    in
    List.Extra.indexedFoldl
        (\index value acc ->
            case Array.get (value |> modBy alphabetLength) alphabet |> Maybe.map Char.toCode of
                Nothing ->
                    -1

                Just codePoint ->
                    codePoint + index + acc
        )
        (List.length numbers)
        numbers
        |> modBy alphabetLength


{-| TESTED

    function toId(num, alphabet) {
        const id = [];
        const chars = alphabet.split('');

        let result = num;

        do {
            id.unshift(chars[result % chars.length]);
            result = Math.floor(result / chars.length);
        } while (result > 0);

        return id.join('');
    }

-}
toId : Int -> Array Char -> String
toId num alphabet =
    -- TODO don't expose this function in package
    let
        charsLength =
            Array.length alphabet

        rec : Int -> List Char -> List Char
        rec lastResult lastId =
            let
                nextId =
                    arrayGetInBounds (lastResult |> modBy charsLength) alphabet :: lastId

                nextResult =
                    -- Cannot use integer division `//` because Elm clamps it to 32 bit, see https://github.com/elm/core/issues/1003
                    toFloat lastResult
                        / toFloat charsLength
                        |> floor
            in
            if nextResult > 0 then
                rec nextResult nextId

            else
                nextId
    in
    rec num []
        |> String.fromList


{-| Only use this if you are sure that the index is between 0 and length of the Array
-}
arrayGetInBounds : Int -> Array Char -> Char
arrayGetInBounds index array =
    Array.get index array
        |> Maybe.withDefault 'ö'


padId : Int -> { alphabet : Array Char, id : List String } -> String
padId minLength { alphabet, id } =
    padIdIfNeeded minLength alphabet id
        |> List.reverse
        |> String.join ""


padIdIfNeeded : Int -> Array Char -> List String -> List String
padIdIfNeeded minLength alphabet id =
    if minLength <= List.length id then
        id

    else
        let
            idWithSeparator : List String
            idWithSeparator =
                (arrayGetInBounds 0 alphabet |> String.fromChar)
                    :: id

            rec : Array Char -> List String -> List String
            rec abc currentId =
                let
                    diff =
                        minLength
                            - List.length currentId
                            |> Debug.log "diff"
                in
                if diff < 1 then
                    currentId

                else
                    let
                        shuffled =
                            shuffle abc

                        nextId : List String
                        nextId =
                            Array.slice 0 diff shuffled
                                |> Array.foldl ((::) << String.fromChar) []
                                |> (\chars -> chars ++ currentId)
                    in
                    rec shuffled nextId
        in
        -- https://github.com/sqids/sqids-spec/blob/40f407169fa0f555b93a197ff0a9e974efa9fba6/src/index.ts#L152-L163
        rec alphabet idWithSeparator


shuffle : Array Char -> Array Char
shuffle before =
    Shuffle.charArray before
        -- TODO decide if I want to catch these (impossible-by-algorithm) cases here, or inside `Shuffle`
        |> Result.Extra.extract (Debug.todo << Debug.toString)
