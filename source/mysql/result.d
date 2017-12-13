﻿/// Structures for data received: rows and result sets (ie, a range of rows).
module mysql.result;

import std.conv;
import std.exception;
import std.range;
import std.string;
import std.variant;

import mysql.commands;
import mysql.connection;
import mysql.exceptions;
import mysql.protocol.extra_types;
import mysql.protocol.packets;
import mysql.protocol.sockets;

/++
A struct to represent a single row of a result set.

Type_Mappings: $(TYPE_MAPPINGS)
+/
/+
The row struct is used for both 'traditional' and 'prepared' result sets.
It consists of parallel arrays of Variant and bool, with the bool array
indicating which of the result set columns are NULL.

I have been agitating for some kind of null indicator that can be set for a
Variant without destroying its inherent type information. If this were the
case, then the bool array could disappear.
+/
struct Row
{
	import mysql.connection;

package:
	Variant[]   _values; // Temporarily "package" instead of "private"
private:
	bool[]      _nulls;

	private static uint calcBitmapLength(uint fieldCount) pure nothrow
	{
		return (fieldCount+7+2)/8;
	}

	//TODO: All low-level commms should be moved into the mysql.protocol package.
	static bool[] consumeNullBitmap(ref ubyte[] packet, uint fieldCount) pure
	{
		uint bitmapLength = calcBitmapLength(fieldCount);
		enforceEx!MYXProtocol(packet.length >= bitmapLength, "Packet too small to hold null bitmap for all fields");
		auto bitmap = packet.consume(bitmapLength);
		return decodeNullBitmap(bitmap, fieldCount);
	}

	// This is to decode the bitmap in a binary result row. First two bits are skipped
	static bool[] decodeNullBitmap(ubyte[] bitmap, uint numFields) pure nothrow
	in
	{
		assert(bitmap.length >= calcBitmapLength(numFields),
				"bitmap not large enough to store all null fields");
	}
	out(result)
	{
		assert(result.length == numFields);
	}
	body
	{
		bool[] nulls;
		nulls.length = numFields;

		// the current byte we are processing for nulls
		ubyte bits = bitmap.front();
		// strip away the first two bits as they are reserved
		bits >>= 2;
		// .. and then we only have 6 bits left to process for this byte
		ubyte bitsLeftInByte = 6;
		foreach(ref isNull; nulls)
		{
			assert(bitsLeftInByte <= 8);
			// processed all bits? fetch new byte
			if (bitsLeftInByte == 0)
			{
				assert(bits == 0, "not all bits are processed!");
				assert(!bitmap.empty, "bits array too short for number of columns");
				bitmap.popFront();
				bits = bitmap.front;
				bitsLeftInByte = 8;
			}
			assert(bitsLeftInByte > 0);
			isNull = (bits & 0b0000_0001) != 0;

			// get ready to process next bit
			bits >>= 1;
			--bitsLeftInByte;
		}
		return nulls;
	}

public:

	/++
	A constructor to extract the column data from a row data packet.
	
	If the data for the row exceeds the server's maximum packet size, then several packets will be
	sent for the row that taken together constitute a logical row data packet. The logic of the data
	recovery for a Row attempts to minimize the quantity of data that is bufferred. Users can assist
	in this by specifying chunked data transfer in cases where results sets can include long
	column values.
	
	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	//TODO: All low-level commms should be moved into the mysql.protocol package.
	this(Connection con, ref ubyte[] packet, ResultSetHeaders rh, bool binary)
	in
	{
		assert(rh.fieldCount <= uint.max);
	}
	body
	{
		scope(failure) con.kill();

		uint fieldCount = cast(uint)rh.fieldCount;
		_values.length = _nulls.length = fieldCount;

		if(binary)
		{
			// There's a null byte header on a binary result sequence, followed by some bytes of bitmap
			// indicating which columns are null
			enforceEx!MYXProtocol(packet.front == 0, "Expected null header byte for binary result row");
			packet.popFront();
			_nulls = consumeNullBitmap(packet, fieldCount);
		}

		foreach(size_t i; 0..fieldCount)
		{
			if(binary && _nulls[i])
			{
				_values[i] = null;
				continue;
			}

			SQLValue sqlValue;
			do
			{
				FieldDescription fd = rh[i];
				sqlValue = packet.consumeIfComplete(fd.type, binary, fd.unsigned, fd.charSet);
				// TODO: Support chunk delegate
				if(sqlValue.isIncomplete)
					packet ~= con.getPacket();
			} while(sqlValue.isIncomplete);
			assert(!sqlValue.isIncomplete);

			if(sqlValue.isNull)
			{
				assert(!binary);
				assert(!_nulls[i]);
				_nulls[i] = true;
				_values[i] = null;
			}
			else
			{
				_values[i] = sqlValue.value;
			}
		}
	}

	/++
	Simplify retrieval of a column value by index.
	
	To check for null, use Variant's .type property:
	`row[index].type == typeid(typeof(null))`

	Type_Mappings: $(TYPE_MAPPINGS)

	Params: i = the zero based index of the column whose value is required.
	Returns: A Variant holding the column value.
	+/
	inout(Variant) opIndex(size_t i) inout
	{
		enforceEx!MYX(_nulls.length > 0, format("Cannot get column index %d. There are no columns", i));
		enforceEx!MYX(i < _nulls.length, format("Cannot get column index %d. The last available index is %d", i, _nulls.length-1));
		return _values[i];
	}

	/++
	Check if a column in the result row was NULL
	
	Params: i = The zero based column index.
	+/
	bool isNull(size_t i) const pure nothrow { return _nulls[i]; }

	/++
	Get the number of elements (columns) in this row.
	+/
	@property size_t length() const pure nothrow { return _values.length; }

	///ditto
	alias opDollar = length;

	/++
	Move the content of the row into a compatible struct
	
	This method takes no account of NULL column values. If a column was NULL,
	the corresponding Variant value would be unchanged in those cases.
	
	The method will throw if the type of the Variant is not implicitly
	convertible to the corresponding struct member.
	
	Type_Mappings: $(TYPE_MAPPINGS)

	Params: S = a struct type.
	               s = an ref instance of the type
	+/
	void toStruct(S)(ref S s) if (is(S == struct))
	{
		foreach (i, dummy; s.tupleof)
		{
			static if(__traits(hasMember, s.tupleof[i], "nullify") &&
					  is(typeof(s.tupleof[i].nullify())) && is(typeof(s.tupleof[i].get)))
			{
				if(!_nulls[i])
				{
					enforceEx!MYX(_values[i].convertsTo!(typeof(s.tupleof[i].get))(),
						"At col "~to!string(i)~" the value is not implicitly convertible to the structure type");
					s.tupleof[i] = _values[i].get!(typeof(s.tupleof[i].get));
				}
				else
					s.tupleof[i].nullify();
			}
			else
			{
				if(!_nulls[i])
				{
					enforceEx!MYX(_values[i].convertsTo!(typeof(s.tupleof[i]))(),
						"At col "~to!string(i)~" the value is not implicitly convertible to the structure type");
					s.tupleof[i] = _values[i].get!(typeof(s.tupleof[i]));
				}
				else
					s.tupleof[i] = typeof(s.tupleof[i]).init;
			}
		}
	}

	void show()
	{
		import std.stdio;

		foreach(Variant v; _values)
			writef("%s, ", v.toString());
		writeln("");
	}
}

/++
A $(LINK2 http://dlang.org/phobos/std_range_primitives.html#isRandomAccessRange, random access range)
of Row.

This is deprecated because the same thing can be achieved by passing a `ResultRange` to
$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`).

This is returned by the `mysql.commands.querySet` and
`mysql.prepared.PreparedImpl.querySet` functions.

Unlike `ResultRange`, this offers random access to the individual rows via
array-like indexing and a `length` member to check the number of rows received
without having to count them.

However, this random access comes with a downside: Unlike `ResultRange`, using
`ResultSet` means ALL the rows are downloaded and stored in
memory before you can access any of them. So use this only if you really need
random-access and you're not likely to be dealing with large numbers of rows.
Otherwise, consider using `query` to receive a `ResultRange` instead.

Type_Mappings: $(TYPE_MAPPINGS)

+/
deprecated("Import std.array and use 'query(...).array' to receive 'Row[]' instead of a ResultSet")
struct ResultSet
{
private:
	Row[]          _rows;      // all rows in ResultSet, we store this to be able to revert() to it's original state
	string[]       _colNames;
	Row[]          _curRows;   // current rows in ResultSet
	size_t[string] _colNameIndicies;

package:
	this (Row[] rows, string[] colNames)
	{
		_rows = rows;
		_curRows = _rows[];
		_colNames = colNames;
	}

public:
	/++
	Make the ResultSet behave as a random access range - empty
	
	+/
	@property bool empty() const pure nothrow { return _curRows.length == 0; }

	/++
	Make the ResultSet behave as a random access range - save
	
	+/
	@property ResultSet save() pure nothrow
	{
		return this;
	}

	/++
	Make the ResultSet behave as a random access range - front
	
	Gets the first row in whatever remains of the Range.
	+/
	@property inout(Row) front() pure inout
	{
		enforceEx!MYX(_curRows.length, "Attempted to get front of an empty ResultSet");
		return _curRows[0];
	}

	/++
	Make the ResultSet behave as a random access range - back
	
	Gets the last row in whatever remains of the Range.
	+/
	@property inout(Row) back() pure inout
	{
		enforceEx!MYX(_curRows.length, "Attempted to get back on an empty ResultSet");
		return _curRows[$-1];
	}

	/++
	Make the ResultSet behave as a random access range - popFront()
	
	+/
	void popFront() pure
	{
		enforceEx!MYX(_curRows.length, "Attempted to popFront() on an empty ResultSet");
		_curRows = _curRows[1..$];
	}

	/++
	Make the ResultSet behave as a random access range - popBack
	
	+/
	void popBack() pure
	{
		enforceEx!MYX(_curRows.length, "Attempted to popBack() on an empty ResultSet");
		_curRows = _curRows[0 .. $-1];
	}

	/++
	Make the ResultSet behave as a random access range - opIndex
	
	Gets the i'th row of whatever remains of the range
	+/
	Row opIndex(size_t i) pure
	{
		enforceEx!MYX(_curRows.length, "Attempted to index into an empty ResultSet range.");
		enforceEx!MYX(i < _curRows.length, "Requested range index out of range");
		return _curRows[i];
	}

	/++
	Make the ResultSet behave as a random access range - length
	
	+/
	@property size_t length() pure const nothrow { return _curRows.length; }
	alias opDollar = length; ///ditto

	/++
	Restore the range to its original span.
	
	Since the range is just a view of the data, we can easily revert to the
	initial state.
	+/
	void revert() pure nothrow
	{
		_curRows = _rows[];
	}

	/++
	Get a row as an associative array by column name
	
	The row in question will be that which was the most recent subject of
	front, back, or opIndex. If there have been no such references it will be front.
	+/
	Variant[string] asAA()
	{
		enforceEx!MYX(_curRows.length, "Attempted use of empty ResultSet as an associative array.");
		Variant[string] aa;
		foreach (size_t i, string s; _colNames)
			aa[s] = front._values[i];
		return aa;
	}

	/// Get the names of all the columns
	@property const(string)[] colNames() const pure nothrow { return _colNames; }

	/// An AA to lookup a column's index by name
	@property const(size_t[string]) colNameIndicies() pure nothrow
	{
		if(_colNameIndicies is null)
		{
			foreach(index, name; _colNames)
				_colNameIndicies[name] = index;
		}

		return _colNameIndicies;
	}
}

/++
An $(LINK2 http://dlang.org/phobos/std_range_primitives.html#isInputRange, input range)
of Row.

This is returned by the `mysql.commands.query` and
`mysql.prepared.PreparedImpl.query` functions.

The rows are downloaded one-at-a-time, as you iterate the range. This allows
for low memory usage, and quick access to the results as they are downloaded.
This is especially ideal in case your query results in a large number of rows.

However, because of that, this `ResultRange` cannot offer random access or
a `length` member. If you need random access, then just like any other range,
you can simply convert this range to an array via
$(LINK2 https://dlang.org/phobos/std_array.html#array, `std.array.array()`).

Type_Mappings: $(TYPE_MAPPINGS)

Example:
---
ResultRange oneAtATime = myConnection.query("SELECT * from myTable");
Row[]       allAtOnce  = myConnection.query("SELECT * from myTable").array;
---
+/
struct ResultRange
{
private:
	Connection       _con;
	ResultSetHeaders _rsh;
	Row              _row; // current row
	string[]         _colNames;
	size_t[string]   _colNameIndicies;
	ulong            _numRowsFetched;
	ulong            _commandID; // So we can keep track of when this is invalidated

	void ensureValid() const pure
	{
		enforceEx!MYXInvalidatedRange(isValid,
			"This ResultRange has been invalidated and can no longer be used.");
	}

package:
	this (Connection con, ResultSetHeaders rsh, string[] colNames)
	{
		_con       = con;
		_rsh       = rsh;
		_colNames  = colNames;
		_commandID = con.lastCommandID;
		popFront();
	}

public:
	/// Check whether the range can still we used, or has been invalidated
	@property bool isValid() const pure nothrow
	{
		return _con !is null && _commandID == _con.lastCommandID;
	}

	/// Make the ResultRange behave as an input range - empty
	@property bool empty() const pure nothrow
	{
		if(!isValid)
			return true;

		return !_con._rowsPending;
	}

	/++
	Make the ResultRange behave as an input range - front
	
	Gets the current row
	+/
	@property inout(Row) front() pure inout
	{
		ensureValid();
		enforceEx!MYX(!empty, "Attempted 'front' on exhausted result sequence.");
		return _row;
	}

	/++
	Make the ResultRange behave as am input range - popFront()
	
	Progresses to the next row of the result set - that will then be 'front'
	+/
	void popFront()
	{
		ensureValid();
		enforceEx!MYX(!empty, "Attempted 'popFront' when no more rows available");
		_row = _con.getNextRow();
		_numRowsFetched++;
	}

	/++
	Get the current row as an associative array by column name

	Type_Mappings: $(TYPE_MAPPINGS)
	+/
	Variant[string] asAA()
	{
		ensureValid();
		enforceEx!MYX(!empty, "Attempted 'front' on exhausted result sequence.");
		Variant[string] aa;
		foreach (size_t i, string s; _colNames)
			aa[s] = _row._values[i];
		return aa;
	}

	/// Get the names of all the columns
	@property const(string)[] colNames() const pure nothrow { return _colNames; }

	/// An AA to lookup a column's index by name
	@property const(size_t[string]) colNameIndicies() pure nothrow
	{
		if(_colNameIndicies is null)
		{
			foreach(index, name; _colNames)
				_colNameIndicies[name] = index;
		}

		return _colNameIndicies;
	}

	/// Explicitly clean up the MySQL resources and cancel pending results
	void close()
	out{ assert(!isValid); }
	body
	{
		if(isValid)
			_con.purgeResult();
	}

	/++
	Get the number of currently retrieved.
	
	Note that this is not neccessarlly the same as the length of the range.
	+/
	@property ulong rowCount() const pure nothrow { return _numRowsFetched; }
}
