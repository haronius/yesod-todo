module Main where

import Yesod as Y
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Conduit (Manager, newManager)
import Database.Persist.Sqlite
    ( ConnectionPool, SqlBackend, runSqlPool, runMigration
    , createSqlitePool, runSqlPersistMPool
    )
import Data.Time (UTCTime, getCurrentTime)
import Control.Applicative ((<$>), (<*>), pure)
import Data.Typeable (Typeable)
import Control.Monad.Logger (runStdoutLoggingT)
import Data.Aeson (toJSON, encode)
import Data.ByteString.Lazy.Char8 as C (unpack)
import Network.HTTP.Types
import Data.Text as T
import Control.Monad (when)
import Network.Wai (requestHeaders)
import Data.Aeson
import GHC.Generics
import Prelude as P
import Database.Esqueleto as E
import Data.Maybe (fromJust)

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
    Todo json
        text String
        complete Bool
        order Int Maybe
    |]

data TodoApp = TodoApp
    {
        connPool :: ConnectionPool
        , httpManage :: Manager
    }

mkYesod "TodoApp" [parseRoutes|
/todo           TodosR POST GET
/todo/#TodoId    TodoR GET PUT PATCH
|]

data ErrBody = ErrBody {
    message :: Text
    , success :: Bool
    } deriving (Generic, Show)

instance ToJSON ErrBody

data PatchPayload = PatchPayload {
    patchText :: Maybe String
    , patchComplete :: Maybe Bool
    , patchOrder :: Maybe Int
    } deriving (Generic, Show)

instance FromJSON PatchPayload where
    parseJSON = withObject "PatchPayload" $ \v -> PatchPayload
        <$> v .:? "text" .!= Nothing
        <*> v .:? "complete" .!= Nothing
        <*> v .:? "order" .!= Nothing 

sendJSONRes :: (ToJSON a) => a -> Int -> HandlerT TodoApp IO String
sendJSONRes x code = sendResponseStatus (mkStatus code "") $ RepJson $ toContent $ (C.unpack $ encode x)
    

instance Yesod TodoApp where
    approot = ApprootStatic "http://localhost:3000"
    errorHandler errorResponse = do
        $(logWarn) (append "Error Response: "
                            $ pack (show errorResponse))
        req <- waiRequest
        let
            errorText NotFound = (404, "Not Found", "Sorry, not found")
            errorText (InternalError msg) = (400, "Bad Request", msg)
            errorText (InvalidArgs m) = (400, "Bad Request", T.unwords m)
            errorText (PermissionDenied msg) = (403, "Forbidden", msg)
            errorText (BadMethod _) = (405, "Method Not Allowed", "Method not supported")
            (code, brief, full) = errorText errorResponse
            in sendResponseStatus
                (mkStatus code brief)
                $ RepJson $ toContent $ encode $ ErrBody (append "Error: " full) False
    
instance YesodPersist TodoApp where
    type YesodPersistBackend TodoApp = SqlBackend

    runDB f = do
        master <- getYesod
        let pool = connPool master
        runSqlPool f pool


sendSuccess :: (ToJSON a) => a -> HandlerT TodoApp IO String
sendSuccess x = sendJSONRes x 200

sendBadReq :: (ToJSON a) => a -> HandlerT TodoApp IO String
sendBadReq x = sendJSONRes x 500

postTodosR :: Handler String
postTodosR = do
    todo <- requireJsonBody
    todoId <- runDB $ insert (todo :: Todo)
    sendSuccess Entity {
        entityKey = todoId
        , entityVal = todo
    }

patchTodo key todo = E.update $ \p -> do
    set p [ TodoOrder E.=. coalesce [val . patchOrder $ todo, p ^. TodoOrder]
        , TodoText E.=. coalesceDefault [val . patchText $ todo] (p ^. TodoText)
        , TodoComplete E.=. coalesceDefault [val . patchComplete $ todo] (p ^. TodoComplete) ]
    where_ (p ^. TodoId E.==. val key)
    

patchTodoR :: Key Todo -> Handler String
patchTodoR key = do
    todo <- requireJsonBody
    _ <- runDB $ patchTodo key todo 
    getTodoR key


getTodoR :: Key Todo -> Handler String
getTodoR key = do
    todo <- runDB $ selectList [TodoId Y.==. key] [LimitTo 1]
    if P.length todo == 1 then sendSuccess $ todo !! 0
    else sendBadReq $ ErrBody "Todo does not exist" False

putTodoR :: Key Todo -> Handler String
putTodoR todoId = do
    todo <- requireJsonBody
    updated <- runDB $ repsert todoId (todo :: Todo)
    sendSuccess Entity {
        entityKey = todoId
        , entityVal = todo
    }
     

getTodosR :: Handler String 
getTodosR = do
    entries <- runDB $ selectList [] [Desc TodoOrder]
    sendSuccess entries

main :: IO ()
main = do
    pool <- runStdoutLoggingT $ createSqlitePool "crud" 10 -- create a new pool
    runSqlPersistMPool (runMigration migrateAll) pool
    manager <- newManager tlsManagerSettings -- create a new HTTP manager
    warp 3000 $ TodoApp pool manager -- start our server
