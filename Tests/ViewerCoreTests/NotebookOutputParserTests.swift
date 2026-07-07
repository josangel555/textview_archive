import XCTest
@testable import ViewerCore

/// TSK-1440 — parsing nbformat cell outputs into the typed model.
final class NotebookOutputParserTests: XCTestCase {

    private func json(_ s: String) -> JSONValue { try! JSONValue.parse(s) }

    func test_streamOutput_arrayText() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"stream","name":"stdout","text":["hello\n","world\n"]}]
        """#))
        XCTAssertEqual(out, [.stream(name: "stdout", text: "hello\nworld\n")])
    }

    func test_streamOutput_stringText_defaultsStdout() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"stream","text":"oops"}]
        """#))
        XCTAssertEqual(out, [.stream(name: "stdout", text: "oops")])
    }

    func test_executeResult_textPlain() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"execute_result","data":{"text/plain":["42"]},"execution_count":1}]
        """#))
        XCTAssertEqual(out, [.text("42")])
    }

    func test_displayData_imagePreferredOverText() {
        // A display_data with BOTH a png and text/plain → the image wins.
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"display_data","data":{"text/plain":"<Figure>","image/png":"iVBORw0KGgo="}}]
        """#))
        XCTAssertEqual(out, [.image(mime: "image/png", base64: "iVBORw0KGgo=")])
    }

    func test_errorOutput_joinsTraceback() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"error","ename":"ValueError","evalue":"bad","traceback":["Trace1\n","Trace2\n"]}]
        """#))
        XCTAssertEqual(out, [.error(ename: "ValueError", evalue: "bad",
                                    traceback: "Trace1\nTrace2\n")])
    }

    func test_unknownType_isRetainedNotDropped() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"future_thing"},{"output_type":"stream","text":"x"}]
        """#))
        XCTAssertEqual(out.count, 2, "count stays faithful")
        XCTAssertEqual(out[0], .unknown(outputType: "future_thing"))
        XCTAssertEqual(out[1], .stream(name: "stdout", text: "x"))
    }

    func test_nilAndNonArray_yieldEmpty() {
        XCTAssertTrue(NotebookOutputParser.parse(nil).isEmpty)
        XCTAssertTrue(NotebookOutputParser.parse(json(#"{"not":"an array"}"#)).isEmpty)
        XCTAssertTrue(NotebookOutputParser.parse(json("[]")).isEmpty)
    }

    func test_imageMimePreferenceOrder_pngBeforeJpeg() {
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"display_data","data":{"image/jpeg":"jjj","image/png":"ppp"}}]
        """#))
        XCTAssertEqual(out, [.image(mime: "image/png", base64: "ppp")], "png preferred")
    }

    func test_emptyImagePayload_fallsBackToText() {
        // An empty png string is not renderable → use text/plain.
        let out = NotebookOutputParser.parse(json(#"""
        [{"output_type":"display_data","data":{"image/png":"","text/plain":"fallback"}}]
        """#))
        XCTAssertEqual(out, [.text("fallback")])
    }
}
