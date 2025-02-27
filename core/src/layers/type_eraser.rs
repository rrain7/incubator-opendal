// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use std::fmt::Debug;
use std::fmt::Formatter;

use async_trait::async_trait;

use crate::raw::*;
use crate::*;

/// TypeEraseLayer will erase the types on internal accessor.
///
/// # Notes
///
/// TypeEraseLayer is not a public accessible layer that can be used by
/// external users. We use this layer to erase any generic types.
pub struct TypeEraseLayer;

impl<A: Accessor> Layer<A> for TypeEraseLayer {
    type LayeredAccessor = TypeEraseAccessor<A>;

    fn layer(&self, inner: A) -> Self::LayeredAccessor {
        TypeEraseAccessor { inner }
    }
}

/// Provide reader wrapper for backend.
pub struct TypeEraseAccessor<A: Accessor> {
    inner: A,
}

impl<A: Accessor> Debug for TypeEraseAccessor<A> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        self.inner.fmt(f)
    }
}

#[async_trait]
impl<A: Accessor> LayeredAccessor for TypeEraseAccessor<A> {
    type Inner = A;
    type Reader = oio::Reader;
    type BlockingReader = oio::BlockingReader;
    type Writer = oio::Writer;
    type BlockingWriter = oio::BlockingWriter;
    type Appender = oio::Appender;
    type Pager = oio::Pager;
    type BlockingPager = oio::BlockingPager;

    fn inner(&self) -> &Self::Inner {
        &self.inner
    }

    async fn read(&self, path: &str, args: OpRead) -> Result<(RpRead, Self::Reader)> {
        self.inner
            .read(path, args)
            .await
            .map(|(rp, r)| (rp, Box::new(r) as oio::Reader))
    }

    fn blocking_read(&self, path: &str, args: OpRead) -> Result<(RpRead, Self::BlockingReader)> {
        self.inner
            .blocking_read(path, args)
            .map(|(rp, r)| (rp, Box::new(r) as oio::BlockingReader))
    }

    async fn write(&self, path: &str, args: OpWrite) -> Result<(RpWrite, Self::Writer)> {
        self.inner
            .write(path, args)
            .await
            .map(|(rp, w)| (rp, Box::new(w) as oio::Writer))
    }

    fn blocking_write(&self, path: &str, args: OpWrite) -> Result<(RpWrite, Self::BlockingWriter)> {
        self.inner
            .blocking_write(path, args)
            .map(|(rp, w)| (rp, Box::new(w) as oio::BlockingWriter))
    }

    async fn append(&self, path: &str, args: OpAppend) -> Result<(RpAppend, Self::Appender)> {
        self.inner
            .append(path, args)
            .await
            .map(|(rp, a)| (rp, Box::new(a) as oio::Appender))
    }

    async fn list(&self, path: &str, args: OpList) -> Result<(RpList, Self::Pager)> {
        self.inner
            .list(path, args)
            .await
            .map(|(rp, p)| (rp, Box::new(p) as oio::Pager))
    }

    fn blocking_list(&self, path: &str, args: OpList) -> Result<(RpList, Self::BlockingPager)> {
        self.inner
            .blocking_list(path, args)
            .map(|(rp, p)| (rp, Box::new(p) as oio::BlockingPager))
    }
}
