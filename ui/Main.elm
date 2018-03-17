module Main exposing (..)

import Array exposing (Array)
import ArrayExtra as Array
import BasicsExtra exposing (..)
import Dict exposing (Dict)
import DictExtra as Dict
import Http
import Html exposing (Html)
import HtmlExtra as Html
import Html.Attributes exposing (href, class)
import Html.Events
import Html.Lazy as Html
import HtmlEventsExtra as HtmlEvents
import Intersection exposing (Intersection)
import Json.Decode as Decode exposing (Decoder)
import JsonDecodeExtra as Decode
import ListExtra as List
import MaybeExtra as Maybe
import NoUiSlider exposing (..)
import Set exposing (Set)
import Setter exposing (..)
import String exposing (toLower)
import Time exposing (Time)


--------------------------------------------------------------------------------
-- Types and type aliases


type TheModel
    = Loading
    | Loaded Model


type alias Model =
    { papers : Array Paper
    , titles : Dict TitleId Title
    , authors : Dict AuthorId Author
    , links : Dict LinkId Link

    -- Cache the minimum and maximum years of all papers, with some weird
    -- unimportant default values since we assume that *some* paper has a year.
    , yearMin : Int
    , yearMax : Int

    -- The title filter and a cached set of title ids that match the filter.
    , titleFilter : String
    , titleFilterIds : Intersection TitleId

    -- An inverted index mapping author ids to the set of papers by that
    -- author.
    , authorsIndex : Dict AuthorId (Set TitleId)

    -- The author filter and a cached set of title ids that match the filter. We
    -- keep both the "live" filter (input text box) and every "facet" that has
    -- been snipped off by pressing 'enter'.
    , authorFilter : String
    , authorFilterIds : Intersection TitleId

    -- Invariant: non-empty strings
    , authorFacets : List ( String, Intersection TitleId )

    -- The year filter and a cached set of title ids that match the filter.
    -- When min == yearMin and max == yearMax + 1, we treat this as a "special"
    -- mode wherein we show papers without any year.
    , yearFilter : { min : Int, max : Int } -- (inclusive, exclusive)
    , yearFilterIds : Intersection TitleId

    -- The intersection of 'titleFilterIds', 'authorFilterIds', 'authorFacets',
    -- and 'yearFilterIds'.
    , visibleIds : Intersection TitleId
    }


type Message
      -- The initial download of ./static/papers.json
    = Blob (Result Http.Error Papers)
      -- The title filter input box contents were modified
    | TitleFilter String
      -- The author filter input box contents were modified
    | AuthorFilter String
      -- 'Enter' was pressed in the author filter input box
    | AuthorFacetAdd
      -- An author was clicked, let's create a facet from it
    | AuthorFacetAdd_ Author
      -- An author facet was clicked, let's remove it
    | AuthorFacetRemove String
      -- The year filter slider was updated
    | YearFilter Int Int


type alias AuthorId =
    Int


{-| Author name. Invariant: non-empty.
-}
type alias Author =
    String


type alias LinkId =
    Int


type alias Link =
    String


type alias TitleId =
    Int


type alias Title =
    String


type alias Papers =
    { titles : Dict TitleId Title
    , authors : Dict AuthorId Author
    , links : Dict LinkId Link
    , authorsIndex : Dict AuthorId (Set TitleId)
    , papers : Array Paper
    }


type alias Paper =
    { title : TitleId
    , authors : Array AuthorId
    , year : Maybe Int
    , references : Array TitleId
    , citations : Array TitleId
    , links : Array LinkId
    , loc : { file : Int, line : Int }
    }



--------------------------------------------------------------------------------
-- Boilerplate main function


main : Program Never TheModel Message
main =
    Html.program
        { init = init
        , subscriptions = subscriptions
        , update = update
        , view = view
        }



--------------------------------------------------------------------------------
-- Initialize the model and GET ./static/papers.json


init : ( TheModel, Cmd Message )
init =
    let
        decodePapers : Decoder Papers
        decodePapers =
            Decode.map5
                (\titles authors links authorsIndex papers ->
                    { titles = titles
                    , authors = authors
                    , links = links
                    , authorsIndex = authorsIndex
                    , papers = papers
                    }
                )
                (Decode.field "a" decodeIds)
                (Decode.field "b" decodeIds)
                (Decode.field "c" decodeIds)
                (Decode.field "e" decodeIndex)
                (decodePaper
                    |> Decode.array
                    |> Decode.field "d"
                )

        decodeIndex : Decoder (Dict Int (Set Int))
        decodeIndex =
            Decode.tuple2 Decode.int Decode.intSet
                |> Decode.array
                |> Decode.map Array.toDict

        decodeIds : Decoder (Dict Int String)
        decodeIds =
            Decode.tuple2 Decode.int Decode.string
                |> Decode.array
                |> Decode.map Array.toDict
    in
        ( Loading
        , Http.send Blob <| Http.get "./static/papers.json" decodePapers
        )


decodePaper : Decoder Paper
decodePaper =
    Decode.map7 Paper
        (Decode.intField "a")
        decodeAuthors
        (Decode.optIntField "c")
        decodeReferences
        decodeCitations
        decodeLinks
        (Decode.map2
            (\file line -> { file = file, line = line })
            (Decode.intField "f")
            (Decode.intField "g")
        )


decodeAuthors : Decoder (Array AuthorId)
decodeAuthors =
    Decode.intArray
        |> Decode.field "b"
        |> Decode.withDefault Array.empty


decodeCitations : Decoder (Array TitleId)
decodeCitations =
    Decode.intArray
        |> Decode.field "h"
        |> Decode.withDefault Array.empty


decodeLinks : Decoder (Array LinkId)
decodeLinks =
    Decode.intArray
        |> Decode.field "e"
        |> Decode.withDefault Array.empty


decodeReferences : Decoder (Array TitleId)
decodeReferences =
    Decode.intArray
        |> Decode.field "d"
        |> Decode.withDefault Array.empty



--------------------------------------------------------------------------------
-- Subscriptions


subscriptions : TheModel -> Sub Message
subscriptions model =
    case model of
        Loading ->
            Sub.none

        Loaded _ ->
            let
                unpack : NoUiSliderOnUpdate -> Message
                unpack values =
                    case values of
                        [ n, m ] ->
                            YearFilter n m

                        _ ->
                            Debug.crash <|
                                "Expected 2 ints; noUiSlider.js sent: "
                                    ++ toString values
            in
                noUiSliderOnUpdate unpack



--------------------------------------------------------------------------------
-- The main update loop


update : Message -> TheModel -> ( TheModel, Cmd Message )
update message model =
    case ( message, model ) of
        ( Blob blob, Loading ) ->
            handleBlob blob

        ( TitleFilter filter, Loaded model ) ->
            handleTitleFilter filter model

        ( AuthorFilter filter, Loaded model ) ->
            handleAuthorFilter filter model

        ( AuthorFacetAdd, Loaded model ) ->
            handleAuthorFacetAdd model

        ( AuthorFacetAdd_ author, Loaded model ) ->
            handleAuthorFacetAdd_ author model

        ( AuthorFacetRemove facet, Loaded model ) ->
            handleAuthorFacetRemove facet model

        ( YearFilter n m, Loaded model ) ->
            handleYearFilter n m model

        _ ->
            ( model, Cmd.none )
                |> Debug.log ("Ignoring message: " ++ toString message)




handleBlob : Result Http.Error Papers -> ( TheModel, Cmd Message )
handleBlob result =
    case result of
        Ok blob ->
            let
                ( yearMin, yearMax ) =
                    Array.foldl
                        (\paper ( n, m ) ->
                            case paper.year of
                                Nothing ->
                                    ( n, m )

                                Just y ->
                                    ( min n y, max m y )
                        )
                        ( 3000, 0 )
                        blob.papers

                model : Model
                model =
                    { papers = blob.papers
                    , titles = blob.titles
                    , authors = blob.authors
                    , links = blob.links
                    , yearMin = yearMin
                    , yearMax = yearMax
                    , titleFilter = ""
                    , titleFilterIds = Intersection.empty
                    , authorsIndex = blob.authorsIndex
                    , authorFilter = ""
                    , authorFilterIds = Intersection.empty
                    , authorFacets = []
                    , yearFilter = { min = yearMin, max = yearMax + 1 }
                    , yearFilterIds = Intersection.empty
                    , visibleIds = Intersection.empty
                    }

                command : Cmd Message
                command =
                    noUiSliderCreate
                        { id = "year-slider"
                        , start = [ yearMin, yearMax + 1 ]
                        , margin = Just 1
                        , limit = Nothing
                        , connect = Just True
                        , direction = Nothing
                        , orientation = Nothing
                        , behavior = Nothing
                        , step = Just 1
                        , range = Just { min = yearMin, max = yearMax + 1 }
                        }
            in
                ( Loaded model, command )

        Err msg ->
            Debug.crash <| toString msg


handleTitleFilter : String -> Model -> ( TheModel, Cmd a )
handleTitleFilter filter model =
    let
        titleFilterIds : Intersection TitleId
        titleFilterIds =
            model.papers
                |> Array.foldl
                    (\paper ->
                        if fuzzyMatch (toLower filter) (toLower <| Dict.unsafeGet model.titles paper.title) then
                            Set.insert paper.title
                        else
                            identity
                    )
                    Set.empty
                |> Intersection.fromSet

        model_ : Model
        model_ =
            { model
                | titleFilter = filter
                , titleFilterIds = titleFilterIds
            }
                |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


handleAuthorFilter : String -> Model -> ( TheModel, Cmd a )
handleAuthorFilter filter model =
    let
        authorFilterIds : Intersection TitleId
        authorFilterIds =
            buildAuthorFilterIds filter model.authors model.authorsIndex

        model_ : Model
        model_ =
            { model
                | authorFilter = filter
                , authorFilterIds = authorFilterIds
            }
                |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


handleAuthorFacetAdd : Model -> ( TheModel, Cmd a )
handleAuthorFacetAdd model =
    let
        model_ : Model
        model_ =
            if String.isEmpty model.authorFilter then
                model
            else
                let
                    authorFilter : String
                    authorFilter =
                        ""

                    authorFacetIds : Intersection TitleId
                    authorFacetIds =
                        Intersection.empty

                    authorFacets : List ( String, Intersection TitleId )
                    authorFacets =
                        if List.member model.authorFilter (List.map Tuple.first model.authorFacets) then
                            model.authorFacets
                        else
                            ( model.authorFilter, model.authorFilterIds )
                                :: model.authorFacets
                in
                    { model
                        | authorFilter = authorFilter
                        , authorFilterIds = authorFacetIds
                        , authorFacets = authorFacets
                    }
                        |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


handleAuthorFacetAdd_ : Author -> Model -> ( TheModel, Cmd a )
handleAuthorFacetAdd_ author model =
    let
        authorFacets : List ( String, Intersection TitleId )
        authorFacets =
            if List.member author (List.map Tuple.first model.authorFacets) then
                model.authorFacets
            else
                let
                    authorFilterIds : Intersection TitleId
                    authorFilterIds =
                        buildAuthorFilterIds author model.authors model.authorsIndex
                in
                    ( author, authorFilterIds ) :: model.authorFacets

        model_ : Model
        model_ =
            { model | authorFacets = authorFacets }
                |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


handleAuthorFacetRemove : String -> Model -> ( TheModel, Cmd a )
handleAuthorFacetRemove facet model =
    let
        authorFacets : List ( String, Intersection TitleId )
        authorFacets =
            model.authorFacets
                |> List.deleteBy (Tuple.first >> equals facet)

        model_ : Model
        model_ =
            { model
                | authorFacets = authorFacets
            }
                |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


handleYearFilter : Int -> Int -> Model -> ( TheModel, Cmd a )
handleYearFilter n m model =
    let
        yearFilter : { min : Int, max : Int }
        yearFilter =
            { min = n, max = m }

        yearFilterIds : Intersection TitleId
        yearFilterIds =
            if n == model.yearMin && m == model.yearMax + 1 then
                Intersection.empty
            else
                model.papers
                    |> Array.foldl
                        (\paper ->
                            case paper.year of
                                Nothing ->
                                    identity

                                Just year ->
                                    if year >= n && year < m then
                                        Set.insert paper.title
                                    else
                                        identity
                        )
                        Set.empty
                    |> Intersection.fromSet

        model_ : Model
        model_ =
            { model
                | yearFilter = yearFilter
                , yearFilterIds = yearFilterIds
            }
                |> rebuildVisibleIds
    in
        ( Loaded model_, Cmd.none )


buildAuthorFilterIds :
    String
    -> Dict AuthorId Author
    -> Dict AuthorId (Set TitleId)
    -> Intersection TitleId
buildAuthorFilterIds s authors authorsIndex =
    if String.isEmpty s then
        Intersection.empty
    else
        authors
            |> Dict.foldl
                (\id author ->
                    if fuzzyMatch (toLower s) (toLower author) then
                        case Dict.get id authorsIndex of
                            Nothing ->
                                identity

                            Just ids ->
                                Set.union ids
                    else
                        identity
                )
                Set.empty
            |> Intersection.fromSet


rebuildVisibleIds : Model -> Model
rebuildVisibleIds model =
    let
        visibleIds : Intersection TitleId
        visibleIds =
            List.foldl
                (Tuple.second >> Intersection.append)
                Intersection.empty
                model.authorFacets
                |> Intersection.append model.titleFilterIds
                |> Intersection.append model.authorFilterIds
                |> Intersection.append model.yearFilterIds
    in
        { model | visibleIds = visibleIds }



--------------------------------------------------------------------------------
-- Render HTML


view : TheModel -> Html Message
view model =
    case model of
        Loading ->
            Html.div
                [ class "container" ]
                [ viewHeader
                , Html.text "Rendering... "
                ]

        Loaded model ->
            Html.div
                [ class "container" ]
                [ viewHeader
                , viewFilters model
                , viewPapers model
                ]


viewHeader : Html a
viewHeader =
    Html.header []
        [ Html.h1 [] [ Html.text "Haskell Papers" ]
        , Html.thunk
            (Html.a
                [ class "subtle-link"
                , href "https://github.com/mitchellwrosen/haskell-papers"
                ]
                [ Html.div [] [ Html.text "contribute on GitHub" ] ]
            )
        ]


viewFilters : Model -> Html Message
viewFilters model =
    Html.p []
        [ Html.lazy viewTitleSearchBox model.titleFilter
        , Html.lazy viewAuthorSearchBox model.authorFilter
        , Html.lazy viewAuthorFacets <| List.map Tuple.first model.authorFacets
        , Html.thunk
            (Html.div
                [ Html.Attributes.id "year-slider" ]
                []
            )
        ]


viewTitleSearchBox : String -> Html Message
viewTitleSearchBox filter =
    Html.div
        [ class "title-search" ]
        [ Html.input
            [ class "title-search-box"
            , Html.Attributes.value filter
            , Html.Attributes.placeholder "Search titles"
            , Html.Events.onInput TitleFilter
            ]
            []
        ]


viewAuthorSearchBox : String -> Html Message
viewAuthorSearchBox filter =
    Html.div
        [ class "author-search" ]
        [ Html.input
            [ class "author-search-box"
            , Html.Attributes.value filter
            , Html.Attributes.placeholder "Search authors"
            , Html.Events.onInput AuthorFilter
            , HtmlEvents.onEnter AuthorFacetAdd
            ]
            []
        ]


viewAuthorFacets : List String -> Html Message
viewAuthorFacets authorFacets =
    case authorFacets of
        [] ->
            Html.empty

        facets ->
            facets
                |> List.map
                    (\facet ->
                        facet
                            |> Html.text
                            |> List.singleton
                            |> Html.div
                                [ class "facet"
                                , Html.Events.onClick (AuthorFacetRemove facet)
                                ]
                    )
                |> List.reverse
                |> Html.div [ class "facets" ]


viewPapers : Model -> Html Message
viewPapers model =
    Html.ul
        [ class "paper-list" ]
        (model.papers
            |> Array.toList
            |> List.map
                (viewPaper
                    (Intersection.toSet model.visibleIds)
                    model.titles
                    model.authors
                    model.links
                    model.titleFilter
                    model.authorFilter
                )
        )


viewPaper :
    Maybe (Set TitleId)
    -> Dict TitleId Title
    -> Dict AuthorId Author
    -> Dict LinkId Link
    -> String
    -> String
    -> Paper
    -> Html Message
viewPaper visible titles authors links titleFilter authorFilter paper =
    Html.li
        (List.filterMap identity
            [ Just (class "paper")
            , case visible of
                Nothing ->
                    Nothing

                Just visible_ ->
                    if Set.member paper.title visible_ then
                        Nothing
                    else
                        Just (Html.Attributes.style [ ( "display", "none" ) ])
            ]
        )
        [ Html.lazy
            (viewTitle
                (Dict.unsafeGet titles paper.title)
                (Array.get 0 paper.links
                    |> Maybe.map (Dict.unsafeGet links)
                )
            )
            titleFilter
        , Html.p
            [ class "details" ]
            [ Html.lazy (viewAuthors authors paper.authors) authorFilter
            , Html.lazy viewYear paper.year
            , Html.lazy viewCitations paper.citations
            ]
        , Html.lazy viewEditLink paper.loc
        ]


viewTitle : Title -> Maybe Link -> String -> Html a
viewTitle title link filter =
    Html.p
        [ class "title" ]
        (case link of
            Nothing ->
                applyLiveFilterStyle filter title

            Just link ->
                [ Html.a
                    [ class "link"
                    , href link
                    ]
                    (applyLiveFilterStyle filter title)
                ]
        )


viewEditLink : { file : Int, line : Int } -> Html a
viewEditLink { file, line } =
    let
        editLink : String
        editLink =
            "https://github.com/mitchellwrosen/haskell-papers/edit/master/papers"
                ++ String.padLeft 3 '0' (toString file)
                ++ ".yaml#L"
                ++ toString line
    in
        Html.a
            [ class "subtle-link edit", href editLink ]
            [ Html.text "(edit)" ]


viewAuthors : Dict AuthorId Author -> Array AuthorId -> String -> Html Message
viewAuthors authors ids filter =
    ids
        |> Array.map
            (\id ->
                let
                    author : Author
                    author =
                        Dict.unsafeGet authors id
                in
                    author
                        |> applyLiveFilterStyle filter
                        |> Html.span
                            [ class "author"
                            , Html.Events.onClick <| AuthorFacetAdd_ author
                            ]
            )
        |> Array.toList
        |> Html.span []


viewYear : Maybe Int -> Html a
viewYear year =
    case year of
        Nothing ->
            Html.empty

        Just year ->
            Html.text (" [" ++ toString year ++ "]")


viewCitations : Array TitleId -> Html a
viewCitations citations =
    case Array.length citations of
        0 ->
            Html.empty

        n ->
            Html.text (" (cited by " ++ toString n ++ ")")


applyLiveFilterStyle : String -> String -> List (Html a)
applyLiveFilterStyle needle haystack =
    case String.uncons needle of
        Nothing ->
            [ Html.text haystack ]

        Just ( x, xs ) ->
            case String.indices (toLower <| String.fromChar x) (toLower haystack) of
                [] ->
                    [ Html.text haystack ]

                n :: _ ->
                    Html.text (String.left n haystack)
                        :: Html.span
                            [ class "highlight" ]
                            [ Html.text (String.slice n (n + 1) haystack) ]
                        :: applyLiveFilterStyle xs (String.dropLeft (n + 1) haystack)



--------------------------------------------------------------------------------
-- Misc. utility functions


{-| Dead-simple greedy fuzzy match algorithm. Search through the haystack for
the needle, in order, without backtracking.

      fuzzyMatch "XYZ" "..X..Y..Z.." = True

-}
fuzzyMatch : String -> String -> Bool
fuzzyMatch needle haystack =
    case String.uncons needle of
        Nothing ->
            True

        Just ( x, xs ) ->
            case String.indices (String.fromChar x) haystack of
                [] ->
                    False

                n :: _ ->
                    fuzzyMatch xs (String.dropLeft (n + 1) haystack)
