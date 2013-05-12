module mysql.db;

public import mysql.connection;

import vibe.core.connectionpool;


class MysqlDB {
   private {
      string m_host;
      string m_user;
      string m_password;
      string m_database;
      ushort m_port;
      SvrCapFlags m_capFlags;
      ConnectionPool!(Connection!mySQLSocketVibeD) m_pool;
   }

   this(string host, string user, string password, string database, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
   {
      m_host = host;
      m_user = user;
      m_password = password;
      m_database = database;
      m_port = port;
      m_capFlags = capFlags;
      m_pool = new ConnectionPool!(Connection!mySQLSocketVibeD)(&createConnection);
   }

   auto lockConnection() { return m_pool.lockConnection(); }

   private Connection!mySQLSocketVibeD createConnection()
   {
      return new Connection!mySQLSocketVibeD(m_host, m_user, m_password, m_database, m_port, m_capFlags);
   }
}
